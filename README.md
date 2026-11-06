# BPB VPN — Windows port (work in progress)

This repository is a GPL-3.0 fork of [bia-pain-bache/BPB-VPN](https://github.com/bia-pain-bache/BPB-VPN).
It preserves the upstream Android application and is being extended with a Windows desktop target.

## Current status

**Windows port is not release-ready yet.** The current CI workflow creates the standard Flutter
Windows runner during the build and produces an unsigned x64 desktop preview. It validates that
the shared Flutter UI can be compiled for Windows; it does not yet provide a working Windows
connection backend.

The Windows implementation is being developed in stages:

1. Flutter Windows runner and repeatable x64 build.
2. Xray process controller and local SOCKS/HTTP proxy mode.
3. Safe Windows system-proxy apply/restore, including recovery after an unexpected exit.
4. Psiphon and Tor Windows processes.
5. Optional TUN mode (requires a separate elevated Wintun implementation).

The first usable Windows release is intended to be **proxy mode only**, without administrator
rights. TUN mode is explicitly out of scope for that first release.

## Build preview locally

Requirements: Windows 10/11 x64, Visual Studio 2022 with the Desktop development with C++ workload,
Flutter stable, and Git.

```powershell
flutter create --platforms=windows --project-name bpb .
bash scripts/fetch_tor_bridges.sh
flutter pub get
flutter analyze
flutter test
flutter build windows --release
```

The executable is written under `build/windows/x64/runner/Release/`.

The GitHub Actions workflow `.github/workflows/windows-preview.yml` runs the same preview build
on Windows and uploads the output as a short-lived artifact. It deliberately does not create a
GitHub Release or label the preview as a functioning VPN client.

## Platform notes

- Android remains the upstream platform and must continue to build.
- Windows currently has no native VPN controller. Do not select VPN mode expecting a tunnel to start.
- Do not commit API tokens, private bridge credentials, signing keys, or certificates.
- Keep upstream attribution and the GPL-3.0 license. Any distributed binary must be accompanied by
  the corresponding source and license notices.

See [HANDOFF.md](HANDOFF.md) for architecture, decisions, and the chronological progress log.
