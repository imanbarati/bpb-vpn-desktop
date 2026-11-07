# External anti-censorship integrations

This document records the safe integration decisions for three reviewed projects. These are
complementary tools, not drop-in Xray outbounds. Do not silently combine their network engines
or let two applications own the Windows system proxy at the same time.

## 1. Shroudly — recommended as a separate Windows companion

Repository: https://github.com/umutxyp/Shroudly  
Latest releases: https://github.com/umutxyp/Shroudly/releases/latest  
License: MIT (repository root).

Shroudly is the strongest Windows-specific addition reviewed in this batch. Its portable C
`shroudly-core` runs a local SOCKS4/4a/5 proxy and applies TLS/HTTP first-payload desynchronization
plus anti-poisoning encrypted DNS. The default engine is designed to run without a driver or
administrator rights. Its Windows Advanced mode is a separate packet-layer backend using
WinDivert and requires elevation; the upstream project pins/downloads the driver and documents
its cleanup/lifecycle.

### Decision

- Recommend Shroudly as an optional, independently installed companion for direct access on
  networks where DPI blocks SNI/Host or poisons DNS.
- Do not vendor or copy its C engine into this repository in this phase. Its engine has its own
  proxy, DNS, auto-probe, ad-block and advanced packet lifecycle; it is a substantial second
  backend, not a small Xray feature.
- Do not run Shroudly and BPB's Windows system-proxy controller concurrently. Both own proxy
  settings and keep restoration state. Disconnect BPB before starting Shroudly, and stop
  Shroudly before reconnecting BPB.
- Shroudly's default userspace mode and its Windows WinDivert Advanced mode are different
  capability tiers. Do not claim that its default mode defeats all stateful DPI or that its
  advanced mode works without administrator approval.
- Do not bundle WinDivert binaries/drivers from an unpinned download. Any future integration
  must pin the upstream Shroudly commit, verify the upstream SHA-256 and license notices, build
  the default and advanced binaries separately, and test driver install/unload and crash cleanup
  on Windows 10/11 x64.
- A future in-process/managed integration should first use Shroudly's documented stdin/stdout
  control protocol or a dedicated child-process adapter. Keep its SOCKS listener on loopback,
  own its process lifetime, and expose it as a distinct connection mode. Never splice its
  desync techniques into Xray's socket path without protocol-level tests.

### Interoperability limits

Shroudly's local proxy is a direct-to-origin anti-DPI path by default. It is not an Xray VLESS
outbound and does not automatically tunnel traffic through a BPB Worker, WARP, MASQUE, or a
Saturn server. A deliberate chain requires explicit upstream semantics and loop-prevention
tests; do not assume that pointing one local proxy at the other creates a valid chain.

## 2. thefeed — keep as a separate companion application/service

Repository: https://github.com/sartoopjj/thefeed  
Client releases: https://github.com/sartoopjj/thefeed/releases/latest  
License: MIT (repository root).

thefeed is a DNS-query transport for its own feed, Telegram/X retrieval, optional Telegram-over-DNS
and end-to-end messenger services. It has separate client/server protocols, DNS resolver
configuration, server keys and domain delegation. It is not an Xray outbound, SOCKS proxy, or
general-purpose IP tunnel.

### Decision

- Recommend the official Windows client as a separate companion app for its feed/messenger use
  case; no thefeed server or protocol is embedded in BPB.
- Users can install the standalone client without operating a server by using the public
  configurations supplied by that project. Self-hosting is a separate deployment requiring
  DNS delegation and an externally reachable DNS service.
- Keep server setup, Telegram login/API credentials, domain keys, resolver bank and messenger
  identity entirely in thefeed. Never copy credentials into BPB settings or logs.
- Do not claim that thefeed carries arbitrary browser traffic or replaces BPB/Xray VPN mode.
  Telegram-over-DNS is a separately advertised feature requiring a compatible thefeed server.
- If a later BPB UI shortcut is added, it must only open the official release page and must
  state that it is an independent application. It must not change WinINet proxy settings.

## 3. behradNG — standard profile interoperability only for now

Repository: https://github.com/dashbehrad/behradNG  
License: GPL-3.0 at repository root; bundled components may retain separate licenses.

behradNG is an Android v2rayNG/Xray fork. Its ordinary VLESS, VMess, Shadowsocks, Trojan,
Hysteria2 and WireGuard profiles are protocol-level formats that may be interoperable with
existing BPB parsers when the exact URI/JSON form is supported. Aether and Saturn are separate
native transports/protocols with platform-specific lifecycle and server components.

### Decision

- Continue to support only standard profile formats already implemented by BPB's importers and
  Xray config builder. Add regression fixtures only for documented, standard links that parse
  into an existing supported outbound.
- Do not advertise Aether or Saturn as supported merely because a profile link can be read.
  Their client/server implementations, handshake, cryptographic framing, probing behavior,
  native binaries and lifecycle must all be ported and interoperability-tested.
- Aether requires its own dependency/license and native ABI review before any Windows port.
  Saturn requires a protocol threat model, cryptographic review, independent server/client
  build, and byte-for-byte interoperability vectors before production consideration.
- Do not import the Alan DPI mutation/OOB code from behradNG into BPB. Review its original
  upstream source, licensing and Windows packet semantics separately; avoid introducing
  unverified packet injection or cryptographic behavior into the Xray process.
- Keep Saturn SSH provisioning out of BPB. It creates/manages remote infrastructure and needs
  a separate consent, credential-storage, host-key verification and server lifecycle design.

## Windows coexistence rules

1. Only one product may own the system proxy at a time: BPB or Shroudly.
2. thefeed does not need to own the system proxy; it remains independent.
3. A behradNG standard profile can be imported only through BPB's existing supported parser.
4. No third-party native engine is shipped until its source revision, license, build inputs,
   hashes, runtime contract, process cleanup and Windows test evidence are recorded in
   `HANDOFF.md`.

## Review sources

- Shroudly engine capability/threat model: https://github.com/umutxyp/Shroudly/blob/main/core/src/CAPABILITIES.md
- Shroudly engine control interface: https://github.com/umutxyp/Shroudly/blob/main/core/src/main.c
- thefeed architecture and deployment: https://github.com/sartoopjj/thefeed#how-it-works
- behradNG integration notes: https://github.com/dashbehrad/behradNG/blob/main/AETHER-INTEGRATION.md
- behradNG Saturn documentation: https://github.com/dashbehrad/behradNG/tree/main/saturn-core
