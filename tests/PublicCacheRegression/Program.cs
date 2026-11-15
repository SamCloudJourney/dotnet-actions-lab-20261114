// Regression for a previously published upstream ASP.NET Core caching fix.
// This deliberately uses localhost, synthetic data, no secrets, and no external targets.
// Compare with https://github.com/dotnet/aspnetcore/commit/f5bdc5345776fd21d8b74c8eda92400f82761772
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using System.Threading;

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.UseUrls("http://127.0.0.1:0");
builder.Services.AddOutputCache();

await using var app = builder.Build();
app.UseRouting();
app.UseOutputCache();

int executions = 0;
app.MapGet("/cache", (HttpContext requestContext) =>
{
    Interlocked.Increment(ref executions);
    return requestContext.Request.Query.ContainsKey("A=B")
        ? "KEY_CONTAINS_EQUALS"
        : requestContext.Request.Query.ContainsKey("A")
            ? "VALUE_CONTAINS_EQUALS"
            : "UNEXPECTED_QUERY";
}).CacheOutput();

await app.StartAsync();
try
{
    var server = app.Services.GetRequiredService<IServer>();
    var address = server.Features.Get<IServerAddressesFeature>()?.Addresses.FirstOrDefault()
        ?? throw new InvalidOperationException("Kestrel did not expose a bound loopback address.");
    var baseAddress = address.TrimEnd('/') + "/cache";

    using var http = new HttpClient();
    string first = await http.GetStringAsync(baseAddress + "?A%3DB=c");
    string repeated = await http.GetStringAsync(baseAddress + "?A%3DB=c");
    string second = await http.GetStringAsync(baseAddress + "?A=B%3Dc");

    if (first != "KEY_CONTAINS_EQUALS" || repeated != first)
    {
        throw new InvalidOperationException("The control request did not return its expected response.");
    }

    Console.WriteLine("FIRST_RESPONSE=" + first);
    Console.WriteLine("REPEATED_RESPONSE=" + repeated);
    Console.WriteLine("SECOND_RESPONSE=" + second);
    Console.WriteLine("ENDPOINT_EXECUTIONS=" + executions);
    if (second == first && executions == 1)
    {
        Console.WriteLine("OBSERVED_PUBLICLY_KNOWN_CACHE_KEY_COLLISION");
    }
    else if (second == "VALUE_CONTAINS_EQUALS")
    {
        Console.WriteLine("NO_COLLISION_OBSERVED");
    }
    else
    {
        throw new InvalidOperationException("Unexpected response or cache behavior.");
    }
}
finally
{
    await app.StopAsync();
}
