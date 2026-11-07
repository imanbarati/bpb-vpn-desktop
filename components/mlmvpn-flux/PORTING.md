# MLM VPN FLUX component — Windows port plan

**Status: initial Dart primitives added; route engine not yet wired.**  
Target: `imanbarati/bpb-vpn-desktop` (Flutter Windows, experimental Xray system-proxy mode).

Upstream: https://github.com/mlmvpn/mlmvpn_android  
Upstream design: https://github.com/mlmvpn/mlmvpn_android/blob/main/FLUX_ARCHITECTURE.md  
Upstream implementation notes: https://github.com/mlmvpn/mlmvpn_android/blob/main/FLUX_IMPLEMENTATION_STATE.md  
License: GPL-3.0 with an additional visible attribution requirement to **mlmvpn**. See the upstream `LICENSE`. Any ported/derived source must retain GPL-compatible licensing, source availability, and visible original-developer credit.

## Decision

Port **FLUX only**, as an independently testable component under `lib/services/mlm_flux/`. Do not fork the Android application wholesale and do not import its Compose UI, Android services, Android-only native libraries, Gereh messenger, Cloudflare control panel, MAE, or unrelated engines into BPB.

FLUX is the best first candidate because its upstream architecture separates a pure-Kotlin control plane from an Xray data plane. The control plane is being reimplemented in Dart for this Flutter application. This is a port, not a binary-compatible reuse of Kotlin code.

## Why a direct copy will not work

The upstream implementation currently assumes:
- Android `MyVpnService` owns a TUN interface;
- its Xray build is a specific modified core (documented as 26.3.27);
- custom Xray features such as the burst observatory and the project's fragment behavior;
- Android network identity, lifecycle, storage, and connectivity callbacks.

BPB Windows currently exposes a local Xray mixed proxy and WinINet system-proxy control only. It does not provide TUN, Wintun, per-app routing, or the upstream custom Xray core. Therefore the Windows component must have a **proxy-mode profile** and must not claim TUN-level leak protection or packet-level failover.

## Component boundary

Target layout:

```
lib/services/mlm_flux/
  flux_route.dart                 candidate model + score breakdown + scorer
  flux_circuit_breaker.dart       cooldown and recovery
  parse/                          strict supported profile parsing (reuse BPB importers)
  probe/                          direct TCP/TLS and local-proxy end-to-end probes
  race/                           bounded candidate race and grace window
  memory/                         per-network route memory and schema migrations
  compile/                        Xray proxy-mode config compilation (verified fields only)
  engine/                          connect, verify, watch, failover orchestration
  store/                           atomic local state persistence
test/mlm_flux_test.dart            scorer, hysteresis, candidate and breaker tests
```

The component must depend on a narrow adapter, not on Flutter widgets or WinINet implementation details:

- `FluxProxyRuntime`: start/reload/stop a generated Xray config and expose the local mixed inbound.
- `FluxProbeClient`: make an HTTP request through a candidate's explicitly mapped local SOCKS/HTTP port.
- `FluxNetworkInfo`: provide a non-identifying network key and current IPv4/IPv6 reachability.
- `FluxStateStore`: persist versioned, redacted route metrics.
- `FluxEvents`: publish state/progress to the existing UI.

BPB remains the sole owner of WinINet proxy settings. FLUX must never independently modify the Windows system proxy.

## Phase 1 — safe proxy-mode FLUX

1. Inventory the exact BPB Xray version and test which upstream FLUX config features it supports. Reject unknown/unsupported fields rather than silently assuming support.
2. Reuse BPB's existing URI parser and outbound builder for VLESS, VMess, Trojan, and Shadowsocks where supported. Add Hysteria2 only after confirming the bundled core supports the exact transport and authentication shape.
3. Race candidates with bounded concurrency and explicit candidate-to-local-port mapping. A successful TCP/TLS handshake is only a reachability signal, never proof of a working proxy.
4. Run a real HTTP request through each candidate's local inbound; verify the observed exit country through independent sources before labeling a country as proven.
5. Rank only verified candidates using RTT, repeated success, stability, freshness, and failure history. Add hysteresis so tiny score changes do not churn the active route.
6. Keep per-network memory local, versioned, atomically written, and free of raw credentials. Hash candidate identity; never log full profile URIs.
7. Connect the winner through the existing BPB proxy controller. On failure, switch only after the replacement candidate has passed the end-to-end probe.
8. Add deterministic unit tests for parsing, explicit port mapping, race ordering, scoring, circuit breaker, stale memory, redaction, and failure rollback.

Phase 1 deliberately omits the upstream TUN-only behavior: FakeDNS routing, transparent per-app routing, packet-level DNS enforcement, IPv6 kill-switch behavior, Xray balancer live switching, and burst-observatory failover.

## Phase 2 — optional advanced Xray features

Only after Phase 1 tests pass:
- evaluate whether BPB's pinned Xray core can be upgraded or safely patched to support the required balancer/observatory fields;
- compare a single generated config with multiple explicit local proxy instances;
- benchmark failover and resource use on Windows 10/11;
- document exactly which transports and Xray features are enabled.

Do not copy a custom Xray binary or native library from an Android APK. Build from pinned, auditable source and record hashes and licenses.

## Deferred projects

- **MAE:** defer. It depends on Android per-app routing, service classification, FakeDNS/TUN routing, live Xray balancer control, and the user's own Cloudflare Worker/account setup. A browser/domain-only Windows version would be a separate product design, not a drop-in port.
- **WARP / MASQUE / Aether / AmneziaWG:** defer until each Windows-native engine, driver/service lifecycle, licensing, and independent interoperability tests are available.
- **FLUX Android UI / widgets / Gereh:** not part of this Windows component.
- Public node sources: do not silently add upstream public lists. Source URLs must be user-visible, configurable, and individually reviewed; credentials and private subscriptions remain local.

## Security and acceptance criteria

- Never claim a route is connected based only on process startup or a successful TCP handshake.
- Never disable certificate validation for VLESS/Trojan.
- Never store raw credentials in route IDs, logs, crash reports, or diagnostics.
- Candidate ports bind to loopback only and are mapped explicitly; no "first available port" ambiguity.
- Bound concurrency, probe timeouts, total race duration, and download sizes.
- A failed FLUX startup leaves the prior BPB proxy state intact; disconnect restores the previous WinINet state through the existing controller.
- FLUX is opt-in and must not replace the user's existing BPB connection mode automatically.
- No Windows release claim until CI, unit tests, and manual Windows connect/disconnect/failure-recovery tests pass.

## Attribution

If source code or a derivative implementation is incorporated, preserve a clear, reasonably visible notice:

> Original developer: mlmvpn — https://github.com/mlmvpn

Keep the upstream license and applicable third-party notices with redistributed source and binaries. The BPB repository is already GPL-3.0; do not relicense the combined derivative under a more restrictive license.

## Current implementation status

Implemented in BPB:
- `lib/services/mlm_flux/flux_route.dart`: candidate/metrics/score models, transparent weighted scorer, and 15% switch hysteresis.
- `lib/services/mlm_flux/flux_circuit_breaker.dart`: three-failure opening threshold and exponential cooldown capped at six hours.
- `test/mlm_flux_test.dart`: deterministic unit tests for score ordering, hysteresis, redacted candidate identity, cooldown, and reset.

The weights in the Dart scorer are an explicit first-pass adaptation for Windows proxy mode, not claimed to be numerically identical to the upstream Android scorer. These primitives are not yet wired to profile parsing, route probes, Xray config generation, connection UI, or the Windows proxy controller. Tests have been authored but have not yet been run in this session. No MLM VPN source, native binary, engine, or public profile source list has been copied into BPB.
