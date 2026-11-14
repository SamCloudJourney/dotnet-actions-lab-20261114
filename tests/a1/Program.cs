using System.Collections;
using System.Reflection;
using System.Runtime.CompilerServices;
using webapp.Components;
using Microsoft.AspNetCore.Components.Server;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddSingleton<LabCoordinator>();
builder.Services.AddRazorComponents().AddInteractiveServerComponents();
var app = builder.Build();

app.UseStatusCodePagesWithReExecute("/not-found", createScopeForStatusCodePages: true);
app.MapStaticAssets();
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
        rows.Add(new { connectionId, ids, hashes, sizes });
    }
    return Results.Ok(rows);
});

app.Run();

public sealed class LabCoordinator
{
    public event Action? VictimRender;
    public void TriggerVictim() => VictimRender?.Invoke();
}
