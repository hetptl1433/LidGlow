# Security and privacy

## Reporting a vulnerability

If this repository has GitHub private vulnerability reporting enabled, use **Security → Report a vulnerability**. Otherwise, open an issue containing only a request for a private reporting channel. Do not post credentials, private agent content, executable exploits, or personal identifiers in a public issue.

Include the affected version or commit, macOS version, a minimal reproduction using synthetic data, and the expected versus observed behavior. Do not attach real prompts, source code from private projects, serial numbers, hardware UUIDs, or complete home-directory paths. The project does not currently promise a response-time SLA.

## Boundaries

- LidGlow does not upload agent events, collect telemetry, or require model API credentials. Its snapshot format contains only an agent source, a SHA-256-derived session identifier, a status, and a timestamp. Session hashes are pseudonymous identifiers, not encryption.
- The native signal writer runs briefly when an agent hook fires. Input is capped at 1 MiB, session identifiers at 4,096 Unicode scalars, and each stored snapshot is small. Unchanged working signals are coalesced for 30 seconds. Normal operation retains at most 256 snapshots and prunes snapshots older than 24 hours when writes occur.
- Signal failures exit successfully and print nothing. They cannot grant permissions or decide whether an agent tool runs. Contended locks and an input producer that never closes stdin have bounded wait times.
- Agent hooks write local files under the user's application support directory. Hook management changes only LidGlow's handlers and saves private backups of existing settings before changes. Those backups can contain other agent settings and remain in the user's agent configuration directory.
- Existing symlinked paths and nonregular files are rejected. Settings updates use atomic replacement and check for concurrent changes immediately before replacement. Locks coordinate LidGlow's own installers; an unrelated editor that ignores the lock can still race the final check and rename.
- The event directory and URL actions are local automation interfaces, not an authentication boundary against another process running as the same user. A same-user process can submit synthetic activity or change lighting settings. URL actions do not execute shell commands. The explicit `lidglow://on` and `lidglow://off` actions opt into hardware control just like the app's On/Off controls; mode and focus actions adjust the selection.
- Hardware access uses private macOS interfaces. An explicit Get started/On/Off choice opts into control; normal later launches remember that choice. Preview mode does not control the logo, and pending recovery blocks automatic acquisition. Automatic Mac lighting and normal Quit restore the saved mode; a crash, forced termination, or private-API change can interrupt restoration. There is no privileged daemon or administrator command.

CI uses isolated configuration directories and never enables hardware control. Developer builds are ad-hoc signed; public binaries need an appropriate release signing and notarization process before they can claim that status.
