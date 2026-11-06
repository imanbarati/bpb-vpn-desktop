# HANDOFF — BPB VPN: Windows port + Chrome extension

This repo is a fork of <https://github.com/bia-pain-bache/BPB-VPN> (GPL-3.0, 24 commits of
history preserved; remote `upstream`). Goal: port the Android app to **Windows** and ship a
companion **Chrome extension** to the Chrome Web Store. Nothing below has been implemented yet —
this file is the plan and the map. Read it fully before touching code.

## 0. Rules for the next agent

- **License:** GPL-3.0. Keep `LICENSE`, keep upstream copyright/attribution, and mark changes.
  Every shipped binary/extension must link to its source. Do not relicense.
- **Don't break Android.** Keep the Android build working; add Windows beside it, don't rewrite.
- **Append to the "Progress log" at the bottom** after each work session. Don't rewrite history.
- Verify before claiming: build it, run it, and say what you did *not* test.
- Things marked **[VERIFY]** are my assumptions from reading the code, not tested facts.
- Never commit secrets (Cloudflare API tokens, keystores, Chrome Web Store keys).

## 1. What upstream is (verified by reading the repo)

A Flutter (Dart SDK ^3.13.5) VPN client for bypassing censorship. It deploys a Cloudflare Worker
(`worker/worker.js`, VLESS over WebSocket using `cloudflare:sockets`) through the Cloudflare API
and also supports WARP, MASQUE, Psiphon, Tor and chained proxies.

| Layer | Where | Portable? |
|---|---|---|
| UI (Material, 20 pages) | `lib/ui/*` | Yes — Flutter. Needs desktop layout polish. |
| Xray config builder (1.9k lines) | `lib/services/xray_config.dart` | **Yes — pure Dart**, produces Xray JSON. Core of the app. |
| Cloudflare / WARP / MASQUE / DNS / proxy URIs | `lib/services/*.dart` | Mostly yes (http + pointycastle). |
| State, settings, prefs | `lib/state`, `lib/models`, `lib/ui/prefs.dart` | Yes. Uses `shared_preferences`, `flutter_secure_storage`. |
| **Native bridge** | `lib/services/vpn_channel.dart` ↔ `android/.../MainActivity.kt` via MethodChannel `bpb/core` + EventChannel `bpb/state` | **No — Android only. This is what to replace.** |
| Android VPN service, TUN, tile, per-app routing | `android/app/src/main/kotlin/com/bpb/` (`BpbVpnService`, `CoreManager`, `TrafficMeter`, …) | No |
| Xray core | `xray/xray.go`, built by `scripts/build_xray.sh` with gomobile into `xray.aar` | Go code reusable; packaging is Android-specific |
| Psiphon | `psiphon/*.go` — a **standalone `main` program** serving local SOCKS5 (+UDP via udpgw, optional DNS), JSON lines on stdout, exits when stdin closes | **Yes — already a CLI**, just needs a Windows build |
| Tor | `scripts/fetch_tor.sh` pulls Tor Project's Android expert bundle (`libtor.so`, `liblyrebird.so`); `TorExit.kt` runs it, control port 10831 | Need Windows expert bundle + port of `TorExit.kt` logic |
| Geo data | `scripts/fetch_geo.sh` (Chocolate4U/Iran-v2ray-rules `geoip.dat`/`geosite.dat`) | Yes |
| MITM CA | `lib/services/mitm_ca.dart`, `MitmCa.kt` | Android installs a CA; Windows needs cert-store flow **[VERIFY]** |
| CI | `.github/workflows/release.yml` (tag `v*` → APKs, needs keystore secrets) | Extend with Windows job |

Key fact for both targets: `xray_config.dart` already emits a **`mixed` inbound** (`tag: mixed-in`,
SOCKS5+HTTP on `127.0.0.1:localProxyPort`, optional LAN auth) and has an `AppMode.proxy` that
omits the TUN inbound entirely. The TUN inbound is `{'tag':'tun','protocol':'tun','settings':{'name':'xray0','MTU':…}}`.

## 2. Part A — Windows port

### Decisions already made
- **Flutter Windows desktop target** reusing the existing Dart UI/logic. Add `windows/` via
  `flutter create --platforms=windows .` (don't touch `android/`).
- Replace the Android native layer with a **Dart `CoreController` abstraction** with two
  implementations: `AndroidCoreController` (current MethodChannel code) and
  `WindowsCoreController` (new). Keep the `VpnStateEvent` / `VpnStatus` types so UI code is unchanged.

### Recommended architecture (**[VERIFY]** each point)
1. **Run Xray as a child process** (`xray.exe`) rather than binding Go into Dart. Build it from
   `xray/` or just use the pinned Xray-core version from `xray/go.mod`; the app writes the JSON
   config to a temp dir and launches `xray.exe run -c config.json`. Set `xray.location.asset` to
   the app data dir for geo files. Statistics/delay-test: either Xray's API inbound
   (stats/handler) over loopback gRPC, or keep a thin Go wrapper exe exposing the same functions
   as `xray/xray.go` (start, stop, delay test, traffic counters, version). A thin wrapper exe that
   speaks JSON lines on stdin/stdout (same style as `psiphon/main.go`) is the lowest-risk option.
2. **Two modes:**
   - **Proxy mode (do first, ships value fast):** Xray with only the mixed inbound; the app sets/restores the
     Windows system proxy (WinINet registry keys + `InternetSetOption` refresh). Must restore on exit/crash.
   - **VPN/TUN mode (second):** Xray's `tun` inbound on Windows requires **Wintun** (`wintun.dll`,
     bundled, needs admin). Needs route setup for the server IP bypass and DNS. Check that the
     Xray-core version pinned in `xray/go.mod` supports `tun` on Windows **[VERIFY]**. Android code relies on
     the app being excluded from its own VPN so Xray sockets bypass the tunnel; on Windows you must
     add explicit routes/bypass for the outbound server and for Psiphon/Tor child processes.
3. **Psiphon:** cross-compile `psiphon/` for `windows/amd64` (adapt `scripts/build_psiphon.sh`), launch as
   child, parse its JSON-line stdout, close stdin to stop. Port the Dart/Kotlin glue in `PsiphonExit.kt`.
4. **Tor:** use Tor Project's Windows expert bundle (adapt `scripts/fetch_tor.sh`, keep SHA-256
   pinning — don't skip hash checks), reuse torrc generation and control-port (10831) status parsing from `TorExit.kt`.
5. **Process lifecycle:** use a Windows Job Object so child processes die with the app.
6. **Secrets/storage:** `flutter_secure_storage` supports Windows. **`mobile_scanner` does not support
   Windows [VERIFY]** — gate QR scanning behind a platform check and offer paste/import-from-file instead
   (`qr_flutter` display is fine). Per-app routing (`per_app_page.dart`, `installedApps`) is
   Android-only; hide on Windows (Xray `process` routing may allow a later version **[VERIFY]**).
7. **Packaging:** MSIX or Inno Setup installer + portable zip. Code signing is a separate cost/decision for the owner.
8. **Windows-only trouble spots:** Defender/SmartScreen reputation, UAC for TUN, firewall prompt
   for LAN sharing, updating `lib/services/updates.dart` to point at the new repo's releases.

### Work items (suggested order)
1. `flutter create --platforms=windows .`, make `flutter build windows` pass with the Android channel stubbed out.
2. Introduce `CoreController` interface; move current `VpnChannel` into `AndroidCoreController`.
3. Proxy-mode on Windows end-to-end with the Cloudflare Worker config (the main upstream use case).
4. System proxy set/restore + tray icon (`tray_manager`/`window_manager` or similar) + start-minimized.
5. Psiphon + Tor child processes.
6. TUN mode with Wintun.
7. Installer, CI job (`windows-latest`) adding a Windows artifact to `release.yml`, version/tag check kept.

## 3. Part B — Chrome extension

### Hard constraint (important, decide early)
A Chrome extension **cannot run Xray, Tor, Psiphon or open raw TCP/UDP sockets**. `chrome.sockets`
is not available to normal MV3 extensions. And the Worker in this project speaks VLESS-over-WebSocket,
which a browser can't use directly as a proxy. So a "pure extension VPN" is not possible with this stack.
**[VERIFY]** the Direct Sockets situation only if you want to explore Isolated Web Apps; it isn't a Web Store path.

### Recommended design: companion extension
The extension is a **controller + proxy configurator** for the Windows app:
- Uses `chrome.proxy` (MV3, `proxy` permission) with a PAC/fixed-server config pointing at the app's
  local mixed inbound (`127.0.0.1:<localProxyPort>`, SOCKS5 or HTTP; add credentials via
  `webRequest.onAuthRequired` if `lanAuth` is on).
- Optional: **Native Messaging** host (registered by the Windows installer) so the extension can
  show status and connect/disconnect the app. Keep the host protocol minimal: `status`, `connect`,
  `disconnect`, `get_proxy_port`. Restrict `allowed_origins` to the extension ID.
- Features: per-site on/off list, "proxy only these domains" PAC rules, a connection indicator,
  and an "app not running" state.
- This gives the browser-only-proxy use case without touching the system-wide settings.

### Chrome Web Store checklist **[VERIFY all against current policy before submitting]**
- Manifest V3; **no remotely hosted code**; minimal permissions (`proxy`, `storage`, `nativeMessaging`, host permissions only if needed).
- Single, clearly described purpose; privacy policy URL; accurate data-use disclosure (the extension should
  collect nothing; say so). VPN/proxy-type extensions get extra scrutiny — read the current
  Developer Program Policies and the "Proxy / VPN" related rules, and don't claim "VPN" if it only routes browser traffic.
- Store listing assets: 128px icon, screenshots, short/long description (English + Persian).
- Developer account registration fee is paid by the owner; don't attempt to register on their behalf.
- Provide a way for the reviewer to test (they won't have the Windows app): document a test mode, or
  a demo video.
- **Risk to flag to the owner:** circumvention tools may be rejected or removed; keep a
  sideloadable `.zip`/CRX path (GitHub Releases) and a Firefox build as fallback.

### Work items
1. Scaffold `extension/` (MV3, TypeScript optional) with options page and popup.
2. `chrome.proxy` set/clear with PAC generation + tests.
3. Native messaging host (small Go or Dart/Node exe) + installer registration (registry key under `HKCU\Software\Google\Chrome\NativeMessagingHosts`).
4. Packaging script → `.zip`; CI artifact.
5. Store listing + privacy policy text.

## 4. Repo layout to aim for

```
lib/                  shared Flutter UI + services (existing)
android/              existing Android target (keep working)
windows/              new Flutter Windows runner
xray/ psiphon/        Go cores (add windows build scripts)
scripts/              add build_*.ps1 / .sh variants for Windows, Tor Windows fetch w/ hashes
extension/            new Chrome MV3 extension (+ native-messaging host)
windows-port/         notes/scratch for the port (delete when done)
.github/workflows/    add windows + extension jobs
```

## 5. Decisions (owner had no preference, so these defaults apply)

1. Repo: `imanbarati/bpb-vpn-desktop`.
2. Windows v1 = **proxy mode only** (no admin rights needed). TUN/VPN mode comes later.
3. No code-signing certificate for now; ship unsigned and document the SmartScreen warning.
4. English UI first; Persian/RTL localization is a later pass.
5. Extension = **proxy-config-only first** (points Chrome at the app's local port); native messaging controller is a later step.

## 6. Status of this repo

- The Windows port work is on branch `windows-port/ci-foundation` and is proposed in [draft PR #1](https://github.com/imanbarati/bpb-vpn-desktop/pull/1). It is not merged.
- Windows Flutter runner scaffolding is generated in CI; Android source files remain unchanged.
- Windows v1 now has an initial Dart controller path for Xray **proxy mode**: it launches the bundled `xray.exe`, waits for the local mixed inbound, snapshots WinINet proxy values, applies the local proxy, and restores the previous values on disconnect or next app startup. A stale PID marker is used to terminate an orphaned Xray process during recovery.
- The Windows Xray executable is built from the repository's pinned `xray/` Go module and staged with geo databases by the workflow.
- This is still a **preview, not a release-ready VPN client**. The controller has not yet been proven by a successful CI run or manual Windows test. TUN/VPN, Psiphon, Tor, Browser Dialer, tray integration, installer, and full Windows UI gating remain unfinished. Some Android-only utility methods still need explicit Windows handling.
- Do not create a public release until the Windows build and tests pass and proxy connect/disconnect/recovery are manually tested on a real Windows machine.

## Progress log

- 2026-11-06 — Scaffolded repo, analyzed upstream architecture, wrote this handoff. No code changed.
- 2026-11-06 — Added a Windows x64 CI preview workflow, Windows status/build documentation, a standalone Xray process entry point (`xray/cmd/bpb-xray`), and a PowerShell build/staging script. CI now builds the shared Flutter UI and the pinned Xray core into the Windows bundle. This still does **not** connect the UI to Xray: Windows `VpnChannel`, safe system-proxy apply/restore, and connection lifecycle remain unimplemented. No Windows VPN release is ready. Next: implement and test the Windows proxy-mode controller, then wire UI state and error handling to it.

- 2026-11-06 — Implemented the first Windows proxy-mode backend in `VpnChannel`: Xray child-process launch, readiness check for the mixed inbound, WinINet system-proxy snapshot/apply/restore, stale-session recovery, log access, and a proxied latency probe. Unsupported TUN, Psiphon, Tor, and Browser Dialer paths fail closed. Windows CI initially failed because the worker minified asset was not generated and Flutter generated an invalid template widget test; workflow now builds the worker asset and removes that generated test, and a pre-existing unused local in the Tor config test was removed. The updated workflow and controller are being validated by GitHub Actions; no release artifact has been verified yet.

- 2026-11-06 — Added checksum verification for Windows geo-asset replacement, Windows file import/export helpers, safe URL opening, and a portable ZIP packager that includes the app, Xray core, README, license, and Windows preview notes. Updated the draft PR description and added per-branch CI concurrency. The latest Windows workflow is still running; no successful build artifact or real-machine proxy test has been confirmed.

- 2026-11-06 — Added a Windows parent-process watcher to the Xray wrapper. The desktop app passes its PID via a small Kernel32 FFI call; Xray holds a process handle and shuts itself down when the Flutter app exits, preventing the proxy process from being left behind after a normal or abnormal app close. The newest CI run is queued for this revision.
