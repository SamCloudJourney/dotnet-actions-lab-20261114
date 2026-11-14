# .NET Actions lab

Manual, researcher-owned .NET test runner on standard GitHub-hosted runners.

## Run

Open **Actions → .NET lab smoke → Run workflow** and choose Ubuntu, Windows, or macOS and a supported .NET SDK. The workflow only runs when dispatched by a repository maintainer. The initial test prints the installed SDK version and a pass marker.

The repository is public. Source, commit history, workflow definitions, run metadata, and logs may be visible or copied while available. Deleting a run or its logs does not retract published source. Keep unpublished vulnerability details, report attachments, credentials, and private evidence out of this repository and its workflow logs. Use this runner only for tests cleared for public disclosure.

The workflow uses standard GitHub-hosted runners, read-only repository permissions, no secrets, no uploaded artifacts, and a 15-minute job timeout. Set the repository's **Settings → Actions → General → Artifact and log retention** to **1 day**. Preserve any needed evidence outside GitHub before deleting a completed run.

For a new public test, edit `tests/run.sh` in a reviewed commit. The workflow does not accept shell commands or code through dispatch inputs.
