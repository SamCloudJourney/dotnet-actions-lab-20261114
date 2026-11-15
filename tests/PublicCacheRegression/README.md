# Public OutputCaching regression check

This test covers a **publicly disclosed and upstream-fixed** cache-key collision (dotnet/aspnetcore commit f5bdc5345776fd21d8b74c8eda92400f82761772).

The test starts a synthetic ASP.NET Core app bound strictly to the runner's loopback interface and checks two different query-parameter structures. It uses no secrets, external websites, exploit payloads, or unpublished findings.

The original .NET lab workflow remains **manual-only**. In Actions, choose ".NET lab smoke", "Run workflow", branch `audit-public-cache-regression-20261115`, runner `ubuntu-latest`, SDK `11.0.100`. Inspect the `OBSERVED_PUBLICLY_KNOWN_CACHE_KEY_COLLISION` or `NO_COLLISION_OBSERVED` marker in the log.

A passing job means the harness ran successfully; the marker indicates the result. This is not a bounty report or a test of unpublished vulnerability details.
