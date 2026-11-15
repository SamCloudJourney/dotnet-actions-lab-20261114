// Public, published upstream regression: dotnet/aspnetcore#67817.
// The test only creates in-memory HttpContext instances and makes no network connections.
// All addresses are documentation/test addresses. No private or unpublished research.
using System.Net;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

var allowedPeer = IPAddress.Parse("10.0.0.1");
var unknownPeer = IPAddress.Parse("10.0.0.2");
var forwardedAddress = IPAddress.Parse("192.0.2.45");

Result known = Evaluate(allowedPeer);
Result unknown = Evaluate(unknownPeer);
Result noPeer = Evaluate(null);

Require(known.RemoteIp is not null && known.RemoteIp.Equals(forwardedAddress), "Known proxy header should apply");
Require(!known.ForwardedHeaderRemains, "Accepted forwarded header should be consumed");
Require(unknown.RemoteIp is not null && unknown.RemoteIp.Equals(unknownPeer), "Unknown proxy header should not apply");
Require(unknown.ForwardedHeaderRemains, "Unknown proxy header must remain");
Require(noPeer.RemoteIp is not null && noPeer.RemoteIp.Equals(forwardedAddress),
    "Pinned 11.0.0 released behavior: null-peer request is permitted through trusted-proxy check");
Require(!noPeer.ForwardedHeaderRemains, "Accepted null-peer header should be consumed");

Console.WriteLine("PUBLISHED_PUBLIC_REGRESSION_67817_REPRODUCED");
Console.WriteLine($"RUNTIME={Environment.Version}");
await KestrelParsing.RunAsync();

static Result Evaluate(IPAddress? remoteIp)
{
    var options = new ForwardedHeadersOptions
    {
        ForwardedHeaders = ForwardedHeaders.XForwardedFor,
        ForwardLimit = 1
    };
    options.KnownProxies.Clear();
    options.KnownIPNetworks.Clear();
    options.KnownProxies.Add(IPAddress.Parse("10.0.0.1"));

    var middleware = new ForwardedHeadersMiddleware(
        _ => Task.CompletedTask,
        NullLoggerFactory.Instance,
        Options.Create(options));

    var context = new DefaultHttpContext();
    context.Connection.RemoteIpAddress = remoteIp;
    context.Request.Headers["X-Forwarded-For"] = "192.0.2.45:443";

    middleware.ApplyForwarders(context);
    return new Result(
        context.Connection.RemoteIpAddress,
        context.Request.Headers.ContainsKey("X-Forwarded-For"));
}

static void Require(bool check, string message)
{
    if (!check)
    {
        Console.Error.WriteLine($"FAIL: {message}");
        Environment.ExitCode = 1;
        throw new InvalidOperationException(message);
    }
}

internal readonly record struct Result(IPAddress? RemoteIp, bool ForwardedHeaderRemains);
