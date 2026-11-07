import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// IPv4 path-MTU probe for Windows. This only measures ordinary ICMP paths; it does
/// not change the Windows interface MTU or measure VPN encapsulation overhead.
class MtuFinder {
  static const defaults = ['1.1.1.1', '8.8.8.8', '9.9.9.9', '77.88.8.8'];

  final Duration timeout;
  final int retries;

  const MtuFinder({
    this.timeout = const Duration(seconds: 3),
    this.retries = 2,
  });

  Future<bool> _ping(String host, int mtu, {bool dontFragment = true}) async {
    final payload = mtu - 28; // IPv4 + ICMP headers.
    if (payload < 0) return false;
    final args = <String>[
      '-4', '-n', '1', '-w', '${timeout.inMilliseconds}',
      if (dontFragment) '-f',
      '-l', '$payload', host,
    ];
    Process? process;
    try {
      process = await Process.start('ping.exe', args, runInShell: false);
      final stdout = process.stdout.drain<void>();
      final stderr = process.stderr.drain<void>();
      final code = await process.exitCode.timeout(timeout + const Duration(seconds: 2));
      await Future.wait([stdout, stderr]);
      return code == 0;
    } on TimeoutException {
      process?.kill();
      return false;
    } on ProcessException {
      rethrow;
    }
  }

  Future<bool> _passes(String host, int mtu) async {
    var successes = 0;
    for (var i = 0; i < retries; i++) {
      if (await _ping(host, mtu)) successes++;
    }
    return successes >= (retries ~/ 2) + 1;
  }

  Future<int?> discover(String host, {int minimum = 576, int maximum = 1500}) async {
    var low = minimum;
    var high = maximum;
    int? best;
    if (!await _passes(host, minimum)) return null;
    best = minimum;
    while (low <= high) {
      final middle = (low + high) ~/ 2;
      if (await _passes(host, middle)) {
        best = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return best;
  }

  Future<Map<String, dynamic>> stability(String host, {int count = 10}) async {
    var received = 0;
    for (var i = 0; i < count; i++) {
      if (await _ping(host, 84, dontFragment: false)) received++;
    }
    final lost = count - received;
    final loss = (lost * 100 / count);
    return {
      'sent': count,
      'received': received,
      'lost': lost,
      'loss_percent': double.parse(loss.toStringAsFixed(2)),
      'status': loss == 0 ? 'EXCELLENT' : loss <= 5 ? 'GOOD' : loss <= 15 ? 'UNSTABLE' : 'POOR',
    };
  }

  Future<Map<String, dynamic>> benchmark(
    List<String> hosts,
    int detected, {
    int count = 3,
    int step = 8,
  }) async {
    final candidates = <int>[];
    for (var mtu = detected; mtu >= (detected - 64).clamp(576, 1500); mtu -= step) {
      candidates.add(mtu);
    }
    if (!candidates.contains(detected)) candidates.insert(0, detected);
    final results = <Map<String, dynamic>>[];
    for (final mtu in candidates) {
      var sent = 0;
      var received = 0;
      for (final host in hosts) {
        for (var i = 0; i < count; i++) {
          sent++;
          if (await _ping(host, mtu)) received++;
        }
      }
      final percent = sent == 0 ? 0.0 : received * 100 / sent;
      results.add({
        'mtu': mtu,
        'sent': sent,
        'successful': received,
        'success_percent': double.parse(percent.toStringAsFixed(2)),
      });
    }
    final stable = results.where((r) => (r['success_percent'] as num) >= 80);
    final best = stable.isEmpty ? null : stable.reduce(
      (a, b) => (a['mtu'] as int) >= (b['mtu'] as int) ? a : b,
    );
    return {'results': results, 'best': best};
  }

  Future<Map<String, dynamic>> run(
    List<String> rawTargets, {
    int minimum = 576,
    int maximum = 1500,
    int margin = 8,
    bool runStability = true,
    bool runBenchmark = true,
  }) async {
    if (!Platform.isWindows) throw UnsupportedError('MTU Finder currently supports Windows only.');
    if (minimum < 576 || maximum > 1500 || minimum >= maximum) {
      throw ArgumentError('MTU range must satisfy 576 <= min < max <= 1500.');
    }
    if (margin < 0 || margin >= maximum) throw ArgumentError('Invalid safety margin.');
    final targets = rawTargets.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet().toList();
    if (targets.isEmpty) throw ArgumentError('Enter at least one IPv4 target.');
    for (final host in targets) {
      final address = InternetAddress.tryParse(host);
      if (address == null || address.type != InternetAddressType.IPv4) {
        throw ArgumentError('Use IPv4 addresses only: $host');
      }
    }

    final mtuResults = <Map<String, dynamic>>[];
    final stabilityResults = <Map<String, dynamic>>[];
    for (final host in targets) {
      final mtu = await discover(host, minimum: minimum, maximum: maximum);
      if (mtu == null) continue;
      mtuResults.add({'host': host, 'ip': host, 'path_mtu': mtu, 'limit_reached': mtu == maximum});
      if (runStability) {
        stabilityResults.add({'host': host, ...await stability(host)});
      }
    }
    if (mtuResults.isEmpty) throw StateError('No successful MTU probes. ICMP may be blocked by the network or target.');
    final detected = mtuResults.map((e) => e['path_mtu'] as int).reduce((a, b) => a < b ? a : b);
    var suggested = (detected - margin).clamp(576, 1500);
    Map<String, dynamic>? benchmarkReport;
    if (runBenchmark) {
      benchmarkReport = await benchmark(
        targets.where((h) => mtuResults.any((r) => r['host'] == h)).toList(),
        detected,
      );
      final best = benchmarkReport['best'] as Map<String, dynamic>?;
      if (best != null) suggested = suggested < (best['mtu'] as int) - margin
          ? suggested : ((best['mtu'] as int) - margin).clamp(576, 1500);
    }
    return {
      'version': '1.1.0',
      'mode': 'Normal IPv4 Internet',
      'vpn_required': false,
      'tun_required': false,
      'tested_targets': targets,
      'detected_path_mtu': detected,
      'safety_margin': margin,
      'recommended_v2ray_mtu': suggested,
      'mtu_results': mtuResults,
      'stability_results': stabilityResults,
      'benchmark_results': benchmarkReport?['results'] ?? [],
      'benchmark_best': benchmarkReport?['best'],
      'settings_changed': false,
      'note': 'Estimate only. VPN/TUN encapsulation overhead is not measured and no network settings were changed.',
    };
  }

  static String encodeReport(Map<String, dynamic> report) =>
      const JsonEncoder.withIndent('  ').convert(report);
}
