# MLM VPN FLUX component — agent handoff

Date: 2026-11-07  
Target repository: `imanbarati/bpb-vpn-desktop`  
Upstream reviewed: `mlmvpn/mlmvpn_android`

## Decision

Port only the upstream FLUX adaptive route-selection concept into BPB as a **Dart component**. Do not merge or vendor the Android app wholesale. Keep the Android source tree and existing BPB behavior untouched.

The full integration constraints and target package layout are in [PORTING.md](PORTING.md).

## Verified upstream facts

- MLM VPN is Kotlin + Jetpack Compose and targets Android; its connection engines are organized as separate packages.
- Upstream describes FLUX's control plane as pure Kotlin and JVM-tested, while its data plane uses its own Xray core and Android TUN service.
- FLUX uses candidate parsing, network capability checks, staged probing, scoring, per-network memory, circuit breakers, and Xray config compilation.
- The upstream FLUX architecture document says the data plane is the project's modified Xray core (documented as 26.3.27) and relies on project-specific features including burst observatory/fragment behavior.
- MAE depends on Android per-app routing, FakeDNS/TUN routing, Xray live-balancer control, and Cloudflare Worker/account integrations. It is not the first Windows component.
- Upstream license is GPL-3.0 with a visible original-developer attribution term for **mlmvpn**. See upstream LICENSE and CONTRIBUTING.md. Keep GPL-compatible terms and visible credit for any copied or derivative code.

Sources:
- https://github.com/mlmvpn/mlmvpn_android
- https://github.com/mlmvpn/mlmvpn_android/blob/main/FLUX_ARCHITECTURE.md
- https://github.com/mlmvpn/mlmvpn_android/blob/main/FLUX_IMPLEMENTATION_STATE.md
- https://github.com/mlmvpn/mlmvpn_android/blob/main/MAE_ARCHITECTURE.md
- https://github.com/mlmvpn/mlmvpn_android/blob/main/LICENSE
- https://github.com/mlmvpn/mlmvpn_android/blob/main/CONTRIBUTING.md

## BPB target constraints

- Flutter desktop UI and Dart service layer.
- Windows backend is currently Xray child process + local mixed proxy + WinINet system proxy.
- No TUN/Wintun, transparent per-app routing, Android VPN service, or Android native libraries.
- BPB's bundled Xray version must be inventoried before assuming compatibility with upstream FLUX config fields.

## Work completed

- Added `components/mlmvpn-flux/PORTING.md` with component boundaries, package layout, phase plan, security criteria, attribution, and explicit exclusions.
- Linked the port plan from root README.
- No MLM VPN code, binaries, public node lists, or Android dependencies have been copied.
- No runtime feature has been added; no CI/build/test claim is made for FLUX.

## Next agent — exact sequence

1. Inspect BPB `xray/go.mod`, `xray/cmd/bpb-xray`, config generation, and the current mixed inbound. Record the exact Xray version and supported outbound/config features.
2. Inspect BPB `lib/services/proxy_uri.dart` and `lib/services/xray_config.dart`. Define a matrix of supported URI types and config capabilities; do not invent support for Hysteria2 or custom FLUX features.
3. Create a small Dart package under `lib/services/mlm_flux/` for data models, redacted stable candidate IDs, scoring, circuit breaker, and versioned state. Keep it pure Dart and add deterministic unit tests first.
4. Add strict parser adapters using BPB's existing parser rather than duplicating URI parsing. Never store/log full profile URIs.
5. Implement bounded TCP/TLS reachability probes and explicit candidate-to-local-port mapping. A handshake is not proof of a working route.
6. Implement an actual HTTP request through each candidate's local proxy and verify the observed exit before marking a route proven.
7. Only then design Xray proxy-mode config compilation and integration with the existing Windows process controller.
8. Add rollback tests: failed FLUX start must leave the previous BPB proxy session intact; disconnect must continue using the existing WinINet restore/recovery path.
9. Run Flutter analysis/tests and Windows CI. A real Windows 10/11 test remains mandatory before release claims.

## Explicitly do not do

- Do not import Android `MyVpnService`, Compose screens, JNI libraries, Aether, WARP, AmneziaWG, Gereh, MAE, or Android-only binaries.
- Do not silently add public profile sources or ship hardcoded credentials.
- Do not replace the BPB Xray binary with an APK-extracted binary.
- Do not modify WinINet from the FLUX component; BPB's existing controller remains the single owner.
- Do not claim full VPN/TUN, DNS leak protection, IPv6 kill-switch, or packet-level failover in proxy mode.
