#!/usr/bin/env bash
# Public-safe runtime check of the published ASP.NET Core optional-certificate sample.
set -euo pipefail
framework=$1
release=$2
case "$framework:$release" in
  net10.0:10.0.15|net11.0:11.0.0) ;;
  *) echo 'Unexpected framework/release pair' >&2; exit 2 ;;
esac
dotnet --list-runtimes | grep -F "Microsoft.AspNetCore.App $release ["

workdir=$(mktemp -d)
sample_pid=''
cleanup() {
  if [[ -n "$sample_pid" ]]; then
    kill "$sample_pid" 2>/dev/null || true
    wait "$sample_pid" 2>/dev/null || true
  fi
  sudo rm -f /usr/local/share/ca-certificates/c023-c037-sample-root.crt
  sudo update-ca-certificates >/dev/null 2>&1 || true
  [[ ! -d "$workdir" ]] || rm -r -- "$workdir"
}
trap cleanup EXIT
cd "$workdir"
base="https://raw.githubusercontent.com/dotnet/aspnetcore/v$release/src/Security/Authentication/Certificate/samples/Certificate.Optional.Sample"
curl --fail --silent --show-error --location "$base/Program.cs" -o Program.cs
curl --fail --silent --show-error --location "$base/Startup.cs" -o Startup.cs
[[ $(git hash-object Program.cs) == cc1fd95a8b0455f32a9b29102ce6e6fb71e6ed6b ]]
[[ $(git hash-object Startup.cs) == e47087f67a4aa5415c315b3229c2515beb008c7d ]]
echo 'SAMPLE_SOURCE_BLOBS_VERIFIED'

# Substitute only test names and the machine-local certificate-store load.
# The published TLS decision, authentication pipeline, and /auth endpoint remain intact.
python3 - <<'PY'
from pathlib import Path
p = Path('Program.cs')
s = p.read_text()
old = '''var serverCertificate = CertificateLoader.LoadFromStoreCert(
                    "localhost", "My", StoreLocation.CurrentUser,
                    allowInvalid: true);'''
assert s.count(old) == 1
s = s.replace(old, 'var serverCertificate = X509Certificate2.CreateFromPemFile("server.crt", "server.key");')
for old, new in [('"127.0.0.1"', '"public.test"'), ('"127.0.0.2"', '"admin.test"')]:
    assert s.count(old) == 1
    s = s.replace(old, new)
p.write_text(s)
PY
cat > Sample.csproj <<XML
<Project Sdk="Microsoft.NET.Sdk.Web">
  <PropertyGroup><TargetFramework>$framework</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable></PropertyGroup>
  <ItemGroup><PackageReference Include="Microsoft.AspNetCore.Authentication.Certificate" Version="$release" /></ItemGroup>
</Project>
XML
cat > NuGet.Config <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<configuration><packageSources><clear /><add key="nuget.org" value="https://api.nuget.org/v3/index.json" /></packageSources></configuration>
XML

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=c023-c037-sample-root' \
  -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' \
  -keyout root.key -out root.crt >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -subj '/CN=public.test' \
  -keyout server.key -out server.csr >/dev/null 2>&1
cat > server.ext <<'EXT'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:public.test,DNS:admin.test
EXT
openssl x509 -req -days 1 -in server.csr -CA root.crt -CAkey root.key -CAcreateserial \
  -extfile server.ext -out server.crt >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -subj '/CN=lab-client' \
  -keyout client.key -out client.csr >/dev/null 2>&1
cat > client.ext <<'EXT'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=clientAuth
EXT
openssl x509 -req -days 1 -in client.csr -CA root.crt -CAkey root.key -CAcreateserial \
  -extfile client.ext -out client.crt >/dev/null 2>&1
sudo cp root.crt /usr/local/share/ca-certificates/c023-c037-sample-root.crt
sudo update-ca-certificates >/dev/null 2>&1

dotnet restore Sample.csproj --configfile NuGet.Config --ignore-failed-sources
dotnet build Sample.csproj --no-restore -c Release
dotnet run --project Sample.csproj --no-build --no-restore -c Release > sample.log 2>&1 &
sample_pid=$!
for _ in $(seq 1 80); do
  if grep -q 'Now listening on:' sample.log; then break; fi
  if ! kill -0 "$sample_pid" 2>/dev/null; then cat sample.log; exit 1; fi
  sleep 0.25
done
grep -q 'Now listening on:' sample.log || { cat sample.log; exit 1; }

request() {
  name=$1 sni=$2 host=$3 path=$4 with_cert=$5
  set -- --http1.1 --noproxy '*' --max-time 6 --silent --show-error \
    --cacert root.crt --resolve "$sni:5001:127.0.0.1" -H "Host: $host:5001" \
    -D "$name.headers" -o "$name.body" -w '%{http_code}' "https://$sni:5001/$path"
  if [[ "$with_cert" == yes ]]; then set -- --cert client.crt --key client.key "$@"; fi
  rc=0
  curl "$@" > "$name.status" 2> "$name.err" || rc=$?
  printf '%s exit=%s http=%s body=%s\n' "$name" "$rc" "$(cat "$name.status")" "$(cat "$name.body" 2>/dev/null || true)"
}
request allowed admin.test admin.test auth yes
request denied admin.test admin.test auth no
request mismatch public.test admin.test auth no
request public_auth public.test public.test auth no
request public_open public.test public.test '' no
[[ $(cat allowed.status) == 200 ]]
grep -q 'Hello lab-client at admin.test:5001' allowed.body
[[ $(cat denied.status) != 200 ]]
[[ $(cat mismatch.status) == 307 ]]
grep -qi '^location: https://admin.test:5001/auth' mismatch.headers
[[ $(cat public_auth.status) == 307 ]]
[[ $(cat public_open.status) == 200 ]]
echo 'OFFICIAL_SAMPLE_GUARD_PASS'
