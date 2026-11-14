# A1: Blazor Server render-batch pool lifetime lab

Two BlazorPack clients run against the shipped ASP.NET Core 11.0.0 assemblies with synthetic circuit data.

The attacker receives and acknowledges its initial batch, then stops reading. Its component produces one 8 MB batch to hold the connection write lock and nine more pending batches. An early ACK for the newest batch returns all pending pooled arrays before SignalR serializes them.

The information-disclosure test uses nine 1.5 MB pending batches, triggers eight independent victim renders, and checks whether the attacker wire contains the victim circuit's random marker. The control skips the early ACK. Both attack and control start from fresh server processes.

The circuit-takeover test uses nine 4 KB pending arrays. The victim then starts a new circuit. SignalR's MessagePack writer rents from the same shared ArrayPool and returns its 4 KB arrays uncleared. The test checks whether the attacker wire contains the exact StartCircuit bearer secret, extracts those bytes from the attacker wire, and calls ConnectCircuit on a new connection. An invalid secret must be denied; the leaked secret must connect and receive the victim's pending render. The control skips the early ACK and must see no secret.

The /lab/state endpoint reports pending IDs, sizes, and managed object identity hashes. The /lab/trigger-victim endpoint schedules independent victim activity. Neither endpoint implements a disputed framework security decision. The attacker WebSocket sends standard hub messages. Logs contain only hashes and booleans, never raw circuit secrets.

This proof establishes cross-circuit disclosure and bearer-secret circuit takeover in this isolated application. It does not yet establish authenticated victim impersonation, code execution, stock-template reachability, or Critical severity.

Run the workflow on branch a1-renderbatch-pool-20261114. Requirements: .NET SDK 11.0.100, Python 3, websocket-client==1.8.0, and msgpack==1.1.1.
