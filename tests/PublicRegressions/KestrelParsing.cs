// Published upstream Kestrel hardening checks only: aspnetcore#68880 and #68465.
// No remote targets: loopback-only, short timeout, documentation/example hostnames.
using System.Net;
using System.Net.Sockets;
using System.Text;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

internal static class KestrelParsing
{
    public static async Task RunAsync()
    {
        var builder = WebApplication.CreateBuilder();
        builder.Logging.ClearProviders();
        builder.WebHost.ConfigureKestrel(opt => opt.Listen(IPAddress.Loopback, 0));
        await using var app = builder.Build();

        app.Run(async context =>
        {
            if (HttpMethods.IsPost(context.Request.Method))
            {
                using var buffer = new MemoryStream();
                await context.Request.Body.CopyToAsync(buffer);
                await context.Response.WriteAsync("read=" + buffer.Length);
            }
            else
            {
                var raw = context.Features.Get<IHttpRequestFeature>()?.RawTarget ?? string.Empty;
                await context.Response.WriteAsync("raw=" + raw + ";path=" + context.Request.Path);
            }
        });

        await app.StartAsync();
        try
        {
            var server = app.Services.GetRequiredService<IServer>();
            var addresses = server.Features.Get<IServerAddressesFeature>()?.Addresses
                ?? throw new InvalidOperationException("Kestrel did not expose bound addresses");
            var endpoint = addresses.Select(x => new Uri(x))
                .FirstOrDefault(x => x.Port > 0 && IPAddress.TryParse(x.Host, out var ip) && IPAddress.IsLoopback(ip))
                ?? throw new InvalidOperationException("Loopback listener not found");
            int port = endpoint.Port;

            // Public bug #68636: backslash normalization in an absolute-form target.
            string backslashRequest = "GET http://example.test/a\\..\\b HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\n\r\n";
            string pathResult = await SendLocalAsync(port, backslashRequest);
            Require(pathResult.StartsWith("HTTP/1.1 200 ", StringComparison.Ordinal),
                "Expected published v11.0.0 absolute-target acceptance, got: " + FirstLine(pathResult));
            Require(pathResult.Contains("raw=http://example.test/a\\..\\b", StringComparison.Ordinal),
                "RawTarget did not preserve example backslashes");
            Console.WriteLine("PUBLIC_68880_RELEASE_TARGET_ACCEPTED: " + FirstLine(pathResult));
            var bodyStart = pathResult.IndexOf("\r\n\r\n", StringComparison.Ordinal);
            if (bodyStart >= 0)
            {
                Console.WriteLine("PUBLIC_68880_RELEASE_TARGET_BODY=" + pathResult[(bodyStart + 4)..].Trim());
            }

            // RFC 9112 control: a mismatched Host must not pass Kestrel authority checks.
            string hostMismatchRequest = "GET http://example.test/path HTTP/1.1\r\nHost: other.test\r\nConnection: close\r\n\r\n";
            string hostMismatchResult = await SendLocalAsync(port, hostMismatchRequest);
            Require(hostMismatchResult.StartsWith("HTTP/1.1 400 ", StringComparison.Ordinal),
                "Kestrel accepted mismatched absolute authority/Host: " + FirstLine(hostMismatchResult));
            Console.WriteLine("HOST_AUTHORITY_MISMATCH_REJECTED: " + FirstLine(hostMismatchResult));

            // Public bug #66794: incomplete chunk-extension token validation, distinct from CRLF checks.
            string invalidExtensionRequest = "POST / HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n2;a=b c\r\nxy\r\n0\r\n\r\n";
            string chunkResult = await SendLocalAsync(port, invalidExtensionRequest);
            Require(chunkResult.StartsWith("HTTP/1.1 200 ", StringComparison.Ordinal),
                "Expected published v11.0.0 chunk-extension acceptance, got: " + FirstLine(chunkResult));
            Require(chunkResult.Contains("read=2", StringComparison.Ordinal),
                "Expected body size 2 in response");
            Console.WriteLine("PUBLIC_68465_RELEASE_EXTENSION_ACCEPTED: " + FirstLine(chunkResult));
        }
        finally
        {
            await app.StopAsync();
        }
    }

    private static async Task<string> SendLocalAsync(int port, string request)
    {
        using var client = new TcpClient(AddressFamily.InterNetwork);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(8));
        await client.ConnectAsync(IPAddress.Loopback, port, timeout.Token);
        using var stream = client.GetStream();
        await stream.WriteAsync(Encoding.ASCII.GetBytes(request), timeout.Token);
        await stream.FlushAsync(timeout.Token);
        using var reader = new StreamReader(stream, Encoding.ASCII);
        return await reader.ReadToEndAsync(timeout.Token);
    }

    private static string FirstLine(string input) => input.Split('\n', 2)[0].Trim();

    private static void Require(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message);
        }
    }
}
