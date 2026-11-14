# A1: Blazor Server render-batch pool lifetime lab

This lab uses synthetic per-circuit markers and the shipped ASP.NET Core 11.0.0 assemblies. It runs two real BlazorPack WebSocket circuits against a generated Blazor Web App.

The attacker client receives its initial batch, acknowledges it, then stops reading while its component produces one 8 MB batch and nine 1.5 MB batches. It sends an ACK for the newest batch before receiving those pending batches. A separate victim circuit then renders eight 1.5 MB batches with a different random marker. The attacker resumes reading and checks whether any delayed render batch contains the victim marker.

The control run keeps the same schedule but skips the early ACK. It must have no shared buffer identities and no foreign marker on the attacker wire. Two independent attack runs each start a fresh server process.

The /lab/state endpoint only reports pending batch IDs, buffer sizes, and managed object identity hashes for evidence. The /lab/trigger-victim endpoint schedules the independent victim render. Neither endpoint changes the framework's ACK, pool, SignalR serialization, or transport decisions. The attacker's WebSocket uses only normal hub messages.

The proof establishes a cross-circuit information disclosure in this isolated application. It does not establish a circuit-secret leak, circuit takeover, code execution, or Critical severity.

Run the workflow on branch a1-renderbatch-pool-20261114. Requirements: .NET SDK 11.0.100, Python 3, websocket-client==1.8.0, and msgpack==1.1.1.
