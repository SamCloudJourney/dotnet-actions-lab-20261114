#!/usr/bin/env bash
# Loopback-only HTTP/3 SNI/authority control for current Kestrel releases.
set -euo pipefail

framework=${1:?net10.0 or net11.0 required}
expected_runtime=${2:?runtime version required}
case "$framework:$expected_runtime" in
  net10.0:10.0.15|net11.0:11.0.0) ;;
  *) echo 'Unexpected framework/runtime pair' >&2; exit 2 ;;
esac

dotnet --list-runtimes | grep -F "Microsoft.AspNetCore.App $expected_runtime ["
workdir=$(mktemp -d)
app_pid=''
cleanup() {
  local rc=$?
  if [[ "$rc" -ne 0 && -f app.log ]]; then
    echo 'Kestrel diagnostics:'
    tail -n 100 app.log
  fi
  if [[ -n "$app_pid" ]]; then
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
  rm -r -- "$workdir"
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
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.AspNetCore.Server.Kestrel.Https;
using System.Net;
using System.Net.Security;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.ConfigureKestrel(options => options.Listen(IPAddress.Loopback, 46023, listen =>
{
    listen.Protocols = HttpProtocols.Http3;
    listen.UseHttps(new TlsHandshakeCallbackOptions
    {
        OnConnection = context =>
        {
            var sni = context.ClientHelloInfo.ServerName;
            var requireCertificate = sni is "admin.test" or "inherit.test";
            Console.WriteLine($"LAB_SNI={sni} REQUIRE_CLIENT_CERT={requireCertificate}");
            if (sni is not ("public.test" or "admin.test" or "inherit.test"))
            {
                throw new AuthenticationException("Unknown lab SNI");
            }
            return ValueTask.FromResult(new SslServerAuthenticationOptions
            {
                ServerCertificate = X509Certificate2.CreateFromPemFile("server.crt", "server.key"),
                ApplicationProtocols = new List<SslApplicationProtocol> { SslApplicationProtocol.Http3 },
                ClientCertificateRequired = requireCertificate,
                RemoteCertificateValidationCallback = (_, certificate, _, _) =>
                    certificate?.Subject == "CN=lab-client"
            });
        }
    });
}));
var app = builder.Build();
app.MapGet("/probe", (HttpContext context) => Results.Json(new
{
    protocol = context.Request.Protocol,
    handshakeFeature = context.Features.Get<ITlsHandshakeFeature>() is not null,
    sni = context.Features.Get<ITlsHandshakeFeature>()?.HostName,
    host = context.Request.Host.Host,
    clientCertificate = context.Connection.ClientCertificate is not null
})).RequireHost("admin.test");
app.MapGet("/strict", (HttpContext context) =>
    context.Connection.ClientCertificate is null ? Results.Unauthorized() : Results.Ok("certificate-present"))
    .RequireHost("admin.test");
app.Run();
CS
printf '{"AllowedHosts":"*"}\n' > appsettings.json
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=public.test' \
  -addext 'subjectAltName=DNS:public.test,DNS:admin.test,DNS:inherit.test' \
  -addext 'extendedKeyUsage=serverAuth' -keyout server.key -out server.crt >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=lab-client' \
  -addext 'extendedKeyUsage=clientAuth' -keyout client.key -out client.crt >/dev/null 2>&1
dotnet restore Lab.csproj --configfile NuGet.Config --ignore-failed-sources
dotnet build Lab.csproj --no-restore -c Release
dotnet run --project Lab.csproj --no-build --no-restore -c Release > app.log 2>&1 &
app_pid=$!
for _ in $(seq 1 80); do
  if grep -q 'Now listening on: https://127.0.0.1:46023' app.log; then break; fi
  if ! kill -0 "$app_pid" 2>/dev/null; then cat app.log; exit 1; fi
  sleep 0.25
done
grep -q 'Now listening on: https://127.0.0.1:46023' app.log

python3 - <<'PY'
import asyncio
import json
import logging
import ssl
from aioquic.asyncio.client import connect
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration

logging.basicConfig(level=logging.DEBUG)

class Client(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.h3 = H3Connection(self._quic)
        self.waiters = {}

    def quic_event_received(self, event):
        for item in self.h3.handle_event(event):
            waiter = self.waiters.get(item.stream_id)
            if waiter is not None:
                waiter['events'].append(item)
                if item.stream_ended:
                    waiter['future'].set_result(waiter['events'])
                    del self.waiters[item.stream_id]

    async def get(self, authority, path):
        stream_id = self._quic.get_next_available_stream_id()
        future = asyncio.get_running_loop().create_future()
        self.waiters[stream_id] = {'future': future, 'events': []}
        self.h3.send_headers(stream_id, [
            (b':method', b'GET'),
            (b':scheme', b'https'),
            (b':authority', (authority + ':46023').encode()),
            (b':path', path.encode()),
        ], end_stream=True)
        self.transmit()
        events = await asyncio.wait_for(future, timeout=8)
        headers = [v for event in events if isinstance(event, HeadersReceived)
                   for k, v in event.headers if k == b':status']
        body = b''.join(event.data for event in events if isinstance(event, DataReceived))
        return int(headers[0]), body.decode()

async def request(name, sni, authority, path, certificate):
    config = QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN)
    config.server_name = sni
    config.verify_mode = ssl.CERT_NONE
    if certificate:
        config.load_cert_chain('client.crt', 'client.key')
    try:
        async with connect('127.0.0.1', 46023, configuration=config,
                           create_protocol=Client) as client:
            status, body = await client.get(authority, path)
            result = {'case': name, 'status': status, 'body': body}
    except Exception as exc:
        result = {'case': name, 'status': 0, 'error': type(exc).__name__ + ': ' + str(exc)}
    print(json.dumps(result), flush=True)
    return result

async def main():
    allowed = await request('allowed', 'admin.test', 'admin.test', '/probe', True)
    denied = await request('denied', 'admin.test', 'admin.test', '/probe', False)
    mismatch = await request('mismatch', 'public.test', 'admin.test', '/probe', False)
    public = await request('public_host', 'public.test', 'public.test', '/probe', False)
    strict = await request('strict_mismatch', 'public.test', 'admin.test', '/strict', False)
    inherited = await request('inherited_denied', 'inherit.test', 'admin.test', '/probe', False)
    assert allowed['status'] == 200, allowed
    assert denied['status'] == 0, denied
    assert mismatch['status'] == 200, mismatch
    assert public['status'] == 404, public
    assert strict['status'] == 401, strict
    assert inherited['status'] == 0, inherited
    allowed_body = json.loads(allowed['body'])
    mismatch_body = json.loads(mismatch['body'])
    assert allowed_body['protocol'] == 'HTTP/3' and allowed_body['clientCertificate'] is True, allowed_body
    assert mismatch_body['protocol'] == 'HTTP/3' and mismatch_body['host'] == 'admin.test' and mismatch_body['clientCertificate'] is False, mismatch_body
    assert allowed_body['handshakeFeature'] is False and mismatch_body['handshakeFeature'] is False, (allowed_body, mismatch_body)
    print('HTTP3_PUBLIC_SMOKE_PASS', flush=True)

asyncio.run(main())
PY
grep -q 'LAB_SNI=admin.test REQUIRE_CLIENT_CERT=True' app.log
grep -q 'LAB_SNI=public.test REQUIRE_CLIENT_CERT=False' app.log
grep -q 'LAB_SNI=inherit.test REQUIRE_CLIENT_CERT=True' app.log
grep '^LAB_SNI=' app.log
