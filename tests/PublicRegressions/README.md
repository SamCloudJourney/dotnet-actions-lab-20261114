# Published .NET regression checks (public runner)

This directory contains only tests derived from already-public upstream bug fixes. No unpublished vulnerability probes, exploit chains, credentials, bounty submissions, or external targets belong here.

Current check: `dotnet/aspnetcore#67817`, a previously disclosed forwarded-header regression. The check uses only in-memory `DefaultHttpContext` and documentation IPs and asserts the observed .NET 11.0.0 release behavior. It is **not** evidence of a new vulnerability or of an exploitable deployment.

Run on an isolated standard GitHub-hosted runner using .NET SDK `11.0.100` as defined by the branch-specific workflow. No network requests are made by the test program.
