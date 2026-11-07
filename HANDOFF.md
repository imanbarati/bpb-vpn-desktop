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
- A regular (non-prerelease) Windows x64 GitHub Release is published automatically after successful pushes to `main`; `windows-v*` tags are also supported. CI has passed Dart analysis/tests and a Windows build on earlier revisions. The latest lifecycle and profile-migration changes are being validated by the current queued release workflow.
- The application remains an **experimental proxy-mode client**, not a full VPN/TUN implementation. A real Windows 10/11 test of connect/disconnect, failed startup, PAC restoration, and forced process termination is still outstanding. TUN/Wintun, Psiphon, Tor, Browser Dialer, tray integration, and installer are not implemented.
- Do not describe the Windows client as fully validated or as a full-device VPN until those real-machine tests and the separate TUN implementation are complete.

## Progress log

- 2026-11-06 — Scaffolded repo, analyzed upstream architecture, wrote this handoff. No code changed.
- 2026-11-06 — Added a Windows x64 CI preview workflow, Windows status/build documentation, a standalone Xray process entry point (`xray/cmd/bpb-xray`), and a PowerShell build/staging script. CI now builds the shared Flutter UI and the pinned Xray core into the Windows bundle. This still does **not** connect the UI to Xray: Windows `VpnChannel`, safe system-proxy apply/restore, and connection lifecycle remain unimplemented. No Windows VPN release is ready. Next: implement and test the Windows proxy-mode controller, then wire UI state and error handling to it.

- 2026-11-06 — Implemented the first Windows proxy-mode backend in `VpnChannel`: Xray child-process launch, readiness check for the mixed inbound, WinINet system-proxy snapshot/apply/restore, stale-session recovery, log access, and a proxied latency probe. Unsupported TUN, Psiphon, Tor, and Browser Dialer paths fail closed. Windows CI initially failed because the worker minified asset was not generated and Flutter generated an invalid template widget test; workflow now builds the worker asset and removes that generated test, and a pre-existing unused local in the Tor config test was removed. The updated workflow and controller are being validated by GitHub Actions; no release artifact has been verified yet.

- 2026-11-06 — Added checksum verification for Windows geo-asset replacement, Windows file import/export helpers, safe URL opening, and a portable ZIP packager that includes the app, Xray core, README, license, and Windows preview notes. Updated the draft PR description and added per-branch CI concurrency. The latest Windows workflow is still running; no successful build artifact or real-machine proxy test has been confirmed.

- 2026-11-06 — Added a Windows parent-process watcher to the Xray wrapper. The desktop app passes its PID via a small Kernel32 FFI call; Xray holds a process handle and shuts itself down when the Flutter app exits, preventing the proxy process from being left behind after a normal or abnormal app close. The newest CI run is queued for this revision.

- 2026-11-06 — Hardened abnormal-exit handling: the Xray child now receives the path to the saved WinINet proxy snapshot and restores the previous registry values plus WinINet refresh itself when the Flutter parent process exits. This closes the gap where killing the app could leave Windows pointed at a dead local proxy. Windows CI is being rerun against this revision; no build artifact has yet been verified.


- 2026-11-07 — GitHub Actions now publishes a **regular (non-prerelease) GitHub Release** on every successful push to `main`, and still supports `windows-v*` tags. Verified release: [windows-main-2-b6635e193fe51eede43ee9f2d798dcb15d4fd3d0](https://github.com/imanbarati/bpb-vpn-desktop/releases/tag/windows-main-2-b6635e193fe51eede43ee9f2d798dcb15d4fd3d0). CI passed and uploaded the portable ZIP plus SHA-256 checksum.

- 2026-11-07 — Hardened Windows proxy lifecycle: startup now awaits stale-session recovery, validates the loopback mixed inbound, catches setup failures from before process launch, waits for child-process termination on rollback, and reports failed WinINet refresh operations. Proxy backup/restore now also preserves and disables the user's PAC URL and automatic proxy discovery (AutoConfigURL / AutoDetect), restoring them on normal disconnect and child-process crash recovery. Renamed the release archive to `BPB-VPN-Windows-x64.zip`. Real Windows connect/disconnect and crash-recovery testing is still required.


- 2026-11-07 — Windows startup now normalizes the saved device profile to supported capabilities: proxy mode is selected automatically, unsupported Psiphon/Tor connection types and exits are removed from the active Windows profile, and Browser Dialer is reset to the standard Worker variant. The Windows connection UI now omits unsupported Psiphon/Tor exit choices and Browser Dialer. The portable archive is now named `BPB-VPN-Windows-x64.zip`; both release and preview workflows use that filename.


- 2026-11-07 — Added a tested `DeviceSettings.forWindowsProxyMode()` migration. It selects Proxy mode, removes unsupported Psiphon/Tor connection and exit choices, resets Browser Dialer and Domain Fronting, disables LAN sharing and per-app routing, and preserves supported chain-proxy choices. The home/settings UI now hides Windows-unsupported options. Added a unit test covering this migration. The Windows release and preview workflows now package the portable build as `BPB-VPN-Windows-x64.zip`. Latest commit: `1ec8eb68b7ad00f5dd3e2498120c1e7b4f0b80ad`; its release workflow is queued behind the prior Windows build.


## 7. External feature references reviewed (2026-11-07)

The owner requested feature work based on these projects:

- <https://github.com/mado3ein/Mtu-Finder>
- <https://github.com/mrchatam/incy-iran-routing>
- <https://github.com/sartoopjj/thefeed>
- <https://github.com/dashbehrad/behradNG>

### Implemented in this repository

1. **Windows Path MTU Finder** — added `lib/services/mtu_finder.dart` and `lib/ui/mtu_finder_page.dart`, exposed from Settings on Windows. It uses Windows `ping.exe` with IPv4 Don't Fragment probes, binary-searches the path MTU, runs packet-loss/stability checks and a small benchmark, calculates a safety-margin recommendation, and can copy or save a JSON report to `%LOCALAPPDATA%\\BPB-VPN\\diagnostics\\mtu_result.json`. It never changes Windows interface settings. It only measures the ordinary IPv4 route; it does not measure tunnel overhead. Since Windows v1 is currently system-proxy mode without a TUN adapter, the recommended value is diagnostic and is not automatically applied.
   - The reference MTU-Finder repository declares no license in its README. No source file was copied; this is an independent Dart implementation of the documented behavior. Re-check licensing before importing any of its code.
   - ICMP/DF packets can be filtered or rate-limited. A failed probe is not proof that a path MTU is smaller; test multiple targets and treat the output as an estimate.

2. **Iran routing preset** — added a Settings action that enables the existing `iran` direct-routing preset and existing `ads`, `malware`, `phishing`, and `cryptominers` block presets. These map to the repository's already-supported Chocolate4U geo assets and Xray routing rules. It does not import the INCY JSON schema or invent unsupported GeoIP tags such as provider-specific CDN identifiers. The user must reconnect for the new rules to take effect.
   - Reference: <https://github.com/mrchatam/incy-iran-routing>. The source profile uses `geosite:category-ir`, `geoip:ir`, private IPs, and provider-specific GeoIP tags. This app currently maps its Iran preset to its own bundled ruleset tags (`geosite:ir` / `geoip:ir`); confirm the exact contents of the pinned geo database before expanding tags.

### Reviewed but deliberately not merged

3. **thefeed** — this is a separate DNS-transport feed reader / Telegram and X reader / E2E messenger with its own server, resolver bank, encrypted protocol, and client UI. It is not a VPN transport or Xray outbound. Embedding its server/client into BPB would add a separate product and security boundary, not a feature of the Windows VPN. It is MIT-licensed, but no code or dependency has been copied. If the owner wants it, develop a separately scoped optional companion client or documented external integration; do not silently bundle a DNS tunnel or server into the VPN.
   - Reference: <https://github.com/sartoopjj/thefeed>.

4. **behradNG** — existing BPB chain support already covers common proxy protocols including VLESS, VMess, Shadowsocks, Trojan, Hysteria2 and WireGuard. The additional Aether transport in the reference is tied to Android native components and is documented there as AGPL-3.0-only; its ABI/page-size/HEV requirements do not make it a drop-in Windows executable. Saturn is a separate custom protocol/server/provisioner with its own crypto, framing, active-probe behavior, and DPI mutation engine. The README's claims are not a substitute for a source-level protocol/security audit or Windows transport implementation. No Aether/Saturn code has been copied, no new transport is advertised, and no unverified custom crypto has been introduced.
   - References: <https://github.com/dashbehrad/behradNG>, <https://github.com/CluvexStudio/Aether>, <https://github.com/DrAlanK/Alan-RIP-Dpi-Windows>.
   - Aether requires a separate AGPL compliance and native-port review. Saturn requires an independent protocol threat model, crypto review, interoperability vectors, and a Windows client/server proof-of-concept before any production integration.

### Required next-agent validation and follow-up

- Run the latest Windows release workflow and inspect **Analyze Dart source**, **Run tests**, **Build Windows x64**, **Build Xray**, **Package ZIP**, **checksum**, and **Publish regular GitHub release**. Do not claim these new commits pass until the latest HEAD run is green.
- Run `flutter analyze` and `flutter test` on the new MTU page/service. Add focused tests for MTU range validation, IPv4 target validation, recommendation margin, and JSON output. The current implementation has not been executed on Windows in this session.
- On a real Windows 10/11 machine, verify `ping.exe -f` behavior, timeout cancellation, packet-loss reporting, save path, and clipboard actions. Test at least two independent IPv4 targets. Confirm the UI remains responsive and that cancellation/closing the page does not leave a ping process behind.
- The MTU tool currently has no cancel button; add cancellation and a maximum total runtime before calling it production-ready.
- Verify the Iran preset against the actual bundled `geoip.dat` / `geosite.dat` version. Confirm precedence (block → direct bypass → proxy catch-all), local DNS behavior, and that no domestic/private destinations leak through a proxy unexpectedly.
- Do not automatically set DNS to public resolvers: the INCY profile's DNS choices are not universally suitable, and this app's DNS pipeline has separate semantics. Keep the preset limited to existing routing toggles until DNS behavior is audited.
- For thefeed, prefer a separate companion repository/app or an explicit user-launched external link. Do not embed thefeed's server, DNS tunnel, messenger, Telegram login, or feed scraping in the VPN process.
- For Aether/Saturn, first inspect source and licenses, create an isolated branch and protocol design, and do not merge until Windows native dependencies, build reproducibility, crypto review, and end-to-end tests are available.
- Preserve GPL-3.0 project obligations and all third-party notices. Never copy code from the MTU-Finder repository until a license is added/confirmed.

## Progress log — additional references

- 2026-11-07 — Reviewed MTU-Finder, INCY Iran routing, thefeed, and behradNG. Added an independent Windows/Dart path-MTU diagnostic page with DF binary search, stability/packet-loss checks, benchmark, safety margin, JSON copy/save, and a Settings entry. Added a one-tap Iran routing preset using only the Xray geo tags and rule presets already supported by this app. No Windows build/test or real-machine probe has yet been verified for these new commits.
- 2026-11-07 — Deliberately did not merge thefeed's independent DNS-feed/messenger product or behradNG's Android-native Aether/custom Saturn transport. TheFeed is not an Xray transport; Aether is Android-native and AGPL-3.0-only; Saturn needs a separate protocol and cryptographic audit plus a Windows implementation. These boundaries and next-agent tasks are documented above.


### Current-state correction — 2026-11-07 (supersedes stale planning text above)

The repository's active work is on the default `main` branch. The old sentence saying the Windows work is only on `windows-port/ci-foundation` / draft PR #1 is historical planning text, not the current delivery state. The regular Windows release workflow has already completed successfully on the preceding Windows lifecycle revision (run [42369310795](https://github.com/imanbarati/bpb-vpn-desktop/actions/runs/42369310795)); that run predates the MTU Finder and Iran preset commits below.

The latest feature commits pushed to `main` are:
- `25bc0277612a304c623e0a83f2b859549c9a5b1d` — Windows MTU diagnostic service.
- `c753178141ace097ff78a5c27ab6975b67de257b` — MTU Finder page.
- `729a6e551511995bb3799eda67669eaa15395295` — Settings entry points and Iran routing preset.
- `2107d90108796cfd7c1de80aaf30536b8ff31412` — async timeout import.
- `b88e3be6c409901e810a37f1a43dc3fd619aed84` — stable Material icons.
- `f814e7b75c3000ea66cae3bd8f2dc39352a10f23` — external project review and this handoff section.
- `8a284d5a5309d012f26881eabfc9cfcae319b712` — README feature status.

Latest known `main` HEAD at the time of this handoff update: `8a284d5a5309d012f26881eabfc9cfcae319b712`. The GitHub Actions run for this exact HEAD has **not been verified here**. The previous green run does not validate the new MTU UI/service or Iran preset. First task for the next agent: inspect the latest `windows-release.yml` run for HEAD, fix any Dart analyzer/test/build failure, and verify that the workflow publishes a regular release with the ZIP and checksum.


### MTU validation follow-up — 2026-11-07

The MTU implementation received a pure target parser and unit tests:
- `734dab76dc015fcf69a809b286b4b431eafb2826` — extract IPv4 parser.
- `54190e7a91f0e1460bb7310f9d9adcf3f965b59d` — use shared parser in the page.
- `0b820fd271939b0d83af6c448b13da2cf87da84c` — add parser tests.
- `a6cfa0e98d78de350f7d0fd451c78777b7f167e6` — correct the whitespace regex.
- `4d541d4b6e3a3e98333db017f38cd556dafbeeea` — correct newline test input.
- `c830be0e1fd68791a09f7d224343d51ca84d2311` — wire the UI to the shared parser.

The earlier README/handoff correction commits are `2ec73fbaede0c0f4c821b7912f3c4297f647804d` and `e70077480790a58ab02450b5d276f280abd7706e`. The latter records the feature head before the parser follow-up. Current code is newer than that recorded head; inspect latest commits and Actions before release. No claim of CI success is made for these follow-up changes.
