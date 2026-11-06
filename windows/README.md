# Windows implementation notes

The Windows runner is generated in CI with Flutter's official Windows template until the runner
files are checked in and customized. This keeps the initial Windows build aligned with the
installed Flutter SDK.

## First milestone

A Windows preview build is not a VPN release. The existing `VpnChannel` uses Android
MethodChannel/EventChannel APIs; no Windows implementation currently handles those calls.
Do not advertise connection, system-proxy, TUN, Psiphon, Tor, tray, or installer support until
those features have been implemented and tested.

The first functional milestone is a Windows x64 proxy-mode controller:

- Launch the pinned Xray core as a child process using the existing JSON config builder.
- Keep the mixed inbound bound to loopback by default.
- Apply the Windows per-user proxy only after Xray is listening.
- Save the prior proxy settings and restore them on disconnect, startup failure, and normal app exit.
- Add a recovery mechanism for abnormal app termination before enabling system-wide proxy changes.
- Reject unsupported VPN/TUN mode with a clear user-facing error rather than invoking Android channels.

Use a Windows Job Object or equivalent process-tree containment before adding child processes.
