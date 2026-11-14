using System.Collections;
using System.Reflection;
using System.Runtime.CompilerServices;
using webapp.Components;
using Microsoft.AspNetCore.Components.Server;
using Microsoft.AspNetCore.SignalR;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Components.Authorization;
using System.Security.Claims;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddSingleton<LabCoordinator>();
builder.Services.AddAuthentication(CookieAuthenticationDefaults.AuthenticationScheme).AddCookie();
builder.Services.AddAuthorization();
builder.Services.AddCascadingAuthenticationState();
builder.Services.AddRazorComponents().AddInteractiveServerComponents();
var app = builder.Build();

app.UseStatusCodePagesWithReExecute("/not-found", createScopeForStatusCodePages: true);
app.UseAuthentication();
app.UseAuthorization();
app.MapStaticAssets();

app.MapPost("/lab/login", async (HttpContext context) =>
{
    if (context.Request.Headers["X-Lab-Setup"] != "owned-lab-victim") return Results.Unauthorized();
    var user = new ClaimsPrincipal(new ClaimsIdentity(new[] { new Claim(ClaimTypes.Name, "victim-lab-user") }, CookieAuthenticationDefaults.AuthenticationScheme));
    await context.SignInAsync(CookieAuthenticationDefaults.AuthenticationScheme, user);
    return Results.Ok(new { authenticated = true });
});
app.MapRazorComponents<App>().AddInteractiveServerRenderMode();

app.MapPost("/lab/trigger-victim", (LabCoordinator lab) =>
{
    lab.TriggerVictim();
    return Results.Ok(new { triggered = true });
});

app.MapGet("/lab/state", (IServiceProvider services) =>
{
    var asm = typeof(CircuitOptions).Assembly;
    var registryType = asm.GetType("Microsoft.AspNetCore.Components.Server.Circuits.CircuitRegistry", true)!;
    var registry = services.GetRequiredService(registryType);
    var circuits = (IEnumerable)registryType.GetProperty("ConnectedCircuits", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)!.GetValue(registry)!;
    var hubType = asm.GetType("Microsoft.AspNetCore.Components.Server.ComponentHub", true)!;
    var managerType = typeof(HubLifetimeManager<>).MakeGenericType(hubType);
    var manager = services.GetRequiredService(managerType);
    var store = (HubConnectionStore)manager.GetType().GetField("_connections", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(manager)!;
    var rows = new List<object>();
    foreach (var pair in circuits)
    {
        var host = pair!.GetType().GetProperty("Value")!.GetValue(pair)!;
        var renderer = host.GetType().GetProperty("Renderer", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)!.GetValue(host)!;
        var client = host.GetType().GetProperty("Client", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)!.GetValue(host)!;
        var connectionId = (string)client.GetType().GetProperty("ConnectionId")!.GetValue(client)!;
        var queue = (IEnumerable)renderer.GetType().GetField("_unacknowledgedRenderBatches", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)!.GetValue(renderer)!;
        var ids = new List<long>();
        var hashes = new List<int>();
        var sizes = new List<int>();
        foreach (var entry in queue)
        {
            ids.Add((long)entry!.GetType().GetProperty("BatchId")!.GetValue(entry)!);
            var data = entry.GetType().GetProperty("Data")!.GetValue(entry)!;
            var buffer = (byte[])data.GetType().GetProperty("Buffer")!.GetValue(data)!;
            hashes.Add(RuntimeHelpers.GetHashCode(buffer));
            sizes.Add(buffer.Length);
        }
        var hubConnection = store[connectionId]!;
        var writeLock = (SemaphoreSlim)typeof(HubConnectionContext).GetField("_writeLock", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(hubConnection)!;
        var scoped = (IServiceProvider)host.GetType().GetProperty("Services", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)!.GetValue(host)!;
        var authProvider = scoped.GetService<AuthenticationStateProvider>();
        var userAuthenticated = authProvider?.GetAuthenticationStateAsync().GetAwaiter().GetResult().User.Identity?.IsAuthenticated ?? false;
        rows.Add(new { connectionId, ids, hashes, sizes, lockHeld = writeLock.CurrentCount == 0, userAuthenticated });
    }
    return Results.Ok(rows);
});

app.Run();

public sealed class LabCoordinator
{
    public event Action? VictimRender;
    public void TriggerVictim() => VictimRender?.Invoke();
}
