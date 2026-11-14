#!/usr/bin/env bash
# Public-safe loopback check of the documented SNI/Host policy separation.
set -euo pipefail

framework=${1:?net10.0 or net11.0 required}
expected_runtime=${2:?runtime version required}
mode=${3:-http1}
case "$framework:$expected_runtime" in
  net10.0:10.0.15|net11.0:11.0.0) ;;
  *) echo 'Unexpected framework/runtime pair' >&2; exit 2 ;;
esac
case "$mode" in
  http1) curl_protocol=--http1.1; kestrel_protocols=Http1 ;;
  http2) curl_protocol=--http2; kestrel_protocols=Http1AndHttp2 ;;
  *) echo 'Unexpected HTTP mode' >&2; exit 2 ;;
esac

dotnet --list-runtimes
dotnet --list-runtimes | grep -F "Microsoft.AspNetCore.App $expected_runtime ["
workdir=$(mktemp -d)
app_pid=''
cleanup() {
  if [[ -n "$app_pid" ]]; then
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
  if [[ -d "$workdir" ]]; then
    rm -r -- "$workdir"
  fi
}
trap cleanup EXIT
cd "$workdir"
cat > NuGet.Config <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<configuration><packageSources><clear /></packageSources></configuration>
XML
cat > Lab.csproj <<XML
<Project Sdk="Microsoft.NET.Sdk.Web">
  <PropertyGroup><TargetFramework>$framework</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable></PropertyGroup>
</Project>
XML
cat > Program.cs <<'CS'
using Microsoft.AspNetCore.Connections.Features;
using Microsoft.AspNetCore.Server.Kestrel.Https;

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.ConfigureKestrel(options => options.ConfigureHttpsDefaults(https =>
{
    https.ClientCertificateValidation = (certificate, _, _) => certificate.Subject == "CN=lab-client";
}));
var app = builder.Build();
app.MapGet("/probe", (HttpContext context) => Results.Json(new
{
    sni = context.Features.Get<ITlsHandshakeFeature>()?.HostName,
    host = context.Request.Host.Host,
    clientCertificate = context.Connection.ClientCertificate is not null
})).RequireHost("admin.test");
app.MapGet("/strict", (HttpContext context) =>
    context.Connection.ClientCertificate is null ? Results.Unauthorized() : Results.Ok("certificate-present"))
    .RequireHost("admin.test");
app.Run();
CS
cat > appsettings.json <<JSON
{
  "Kestrel": {
    "Endpoints": {
      "Https": {
        "Url": "https://127.0.0.1:46023",
        "Protocols": "$kestrel_protocols",
        "ClientCertificateMode": "RequireCertificate",
        "Certificate": { "Path": "server.crt", "KeyPath": "server.key" },
        "Sni": {
          "public.test": { "ClientCertificateMode": "NoCertificate" },
          "admin.test": { "ClientCertificateMode": "RequireCertificate" },
          "inherit.test": { "Protocols": "$kestrel_protocols" }
        }
      }
    }
  }
}
JSON
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=public.test' \
  -addext 'subjectAltName=DNS:public.test,DNS:admin.test,DNS:inherit.test' \
  -addext 'extendedKeyUsage=serverAuth' -keyout server.key -out server.crt >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=lab-client' \
  -addext 'extendedKeyUsage=clientAuth' -keyout client.key -out client.crt >/dev/null 2>&1
dotnet restore Lab.csproj --configfile NuGet.Config --ignore-failed-sources
dotnet build Lab.csproj --no-restore -c Release
dotnet run --project Lab.csproj --no-build --no-restore -c Release > app.log 2>&1 &
app_pid=$!
for _ in $(seq 1 60); do
  if grep -q 'Now listening on: https://127.0.0.1:46023' app.log; then break; fi
  if ! kill -0 "$app_pid" 2>/dev/null; then cat app.log; exit 1; fi
  sleep 0.25
done
grep -q 'Now listening on: https://127.0.0.1:46023' app.log

request() {
  local name=$1 sni=$2 host=$3 path=$4 with_cert=$5
  local -a args=("$curl_protocol" --noproxy '*' --max-time 6 --silent --show-error
    --cacert server.crt --resolve "$sni:46023:127.0.0.1" -H "Host: $host:46023"
    -D "$name.headers" -o "$name.body" -w '%{http_code}' "https://$sni:46023/$path")
  if [[ "$with_cert" == yes ]]; then args=(--cert client.crt --key client.key "${args[@]}"); fi
  local rc=0
  curl "${args[@]}" > "$name.status" 2> "$name.err" || rc=$?
  printf '%s exit=%s http=%s body=%s\n' "$name" "$rc" "$(cat "$name.status")" "$(cat "$name.body" 2>/dev/null || true)"
}

request allowed admin.test admin.test probe yes
request denied admin.test admin.test probe no
request mismatch public.test admin.test probe no
request public_host public.test public.test probe no
request strict_mismatch public.test admin.test strict no
request inherited_allowed inherit.test admin.test probe yes
request inherited_denied inherit.test admin.test probe no

[[ $(cat allowed.status) == 200 ]]
[[ $(cat denied.status) != 200 ]]
[[ $(cat mismatch.status) == 200 ]]
[[ $(cat public_host.status) == 404 ]]
[[ $(cat strict_mismatch.status) == 401 ]]
[[ $(cat inherited_allowed.status) == 200 ]]
[[ $(cat inherited_denied.status) == 000 ]]
if [[ "$mode" == http2 ]]; then
  grep -q '^HTTP/2 ' allowed.headers
  grep -q '^HTTP/2 ' mismatch.headers
  grep -q '^HTTP/2 ' strict_mismatch.headers
  grep -q '^HTTP/2 ' inherited_allowed.headers
fi
python3 - <<'PY'
import json
allowed=json.load(open('allowed.body'))
mismatch=json.load(open('mismatch.body'))
inherited=json.load(open('inherited_allowed.body'))
assert allowed == {'sni':'admin.test','host':'admin.test','clientCertificate':True}, allowed
assert mismatch == {'sni':'public.test','host':'admin.test','clientCertificate':False}, mismatch
assert inherited == {'sni':'inherit.test','host':'admin.test','clientCertificate':True}, inherited
PY
echo "PUBLIC_SMOKE_PASS $mode"
