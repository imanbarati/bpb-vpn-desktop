# Windows implementation notes

The Windows runner is generated in CI with Flutter's official Windows template. The Android
runner and Kotlin VPN service remain separate and unchanged.

## Implemented preview path

The Windows branch now routes VpnChannel to a Dart desktop controller for a limited first
milestone:

- Launch the pinned Xray core as a child process using the existing JSON config builder.
- Require the loopback mixed inbound on port 10808 and wait for it to accept connections.
- Apply the current-user WinINet system proxy only after Xray is listening.
- Snapshot the prior ProxyEnable, ProxyServer, ProxyOverride, AutoConfigURL (PAC), and AutoDetect registry values.
- Disable PAC and automatic proxy discovery while connected, then restore the user's previous values on disconnect or crash recovery.
- Restore those values on disconnect, Xray exit, or recovery during the next app launch.
- Record the child PID so an orphaned Xray process can be terminated during recovery.
- Start in Proxy mode automatically on Windows; hide VPN/TUN, Psiphon, Tor, and Browser Dialer choices that the Windows backend cannot run. The backend still rejects unsupported requests defensively.

This implementation is experimental. It has not yet passed a complete Windows CI build or a
manual test on a real Windows machine. The proxy restore path must be exercised before release.

## Remaining release gates

1. Pass Windows Dart analysis, unit tests, Flutter release build, and Xray cross-build in CI.
2. Manually test connect/disconnect, failed startup, unexpected Xray exit, and app restart recovery.
3. Add UI gating for Android-only settings and utilities.
4. Add tray integration and a signed or clearly documented unsigned installer.
5. Port Psiphon and Tor as Windows child processes.
6. Implement TUN separately with Wintun, route bypass, DNS handling, and elevation.

Do not publish a GitHub Release until the proxy path is tested on Windows. Use [HANDOFF.md](../HANDOFF.md)
for the architecture and progress history.
