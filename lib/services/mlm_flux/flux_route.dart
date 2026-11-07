import 'dart:math' as math;

/// A candidate route after strict parsing by BPB's existing [ProxyUri] importer.
///
/// [id] must be a stable, non-secret identifier (for example SHA-256 of a canonicalized
/// profile with credentials excluded from logs). Never use the raw share URI as an ID.
class FluxRouteCandidate {
  final String id;
  final String protocol;
  final String host;
  final int port;
  final String? expectedCountry;
  final bool requiresTls;
  final bool usesFragment;
  final bool hasVerifiedCertificate;

  const FluxRouteCandidate({
    required this.id,
    required this.protocol,
    required this.host,
    required this.port,
    this.expectedCountry,
    this.requiresTls = true,
    this.usesFragment = false,
    this.hasVerifiedCertificate = true,
  }) : assert(id != ''),
       assert(host != ''),
       assert(port > 0 && port <= 65535);

  @override
  String toString() => 'FluxRouteCandidate($id, $protocol, $host:$port)';
}

/// Measurements gathered by real probes. RTT values are milliseconds; throughput is Mbps.
class FluxRouteMetrics {
  final List<double> rttSamplesMs;
  final double successEwma;
  final double? throughputMbps;
  final double? handshakeMs;
  final DateTime? lastVerifiedAt;
  final int consecutiveFailures;

  const FluxRouteMetrics({
    this.rttSamplesMs = const [],
    this.successEwma = 1,
    this.throughputMbps,
    this.handshakeMs,
    this.lastVerifiedAt,
    this.consecutiveFailures = 0,
  }) : assert(successEwma >= 0 && successEwma <= 1),
       assert(consecutiveFailures >= 0);
}

/// Transparent score breakdown; higher [total] is better (0–100).
class FluxRouteScore {
  final double total;
  final double latency;
  final double success;
  final double stability;
  final double throughput;
  final double freshness;
  final double handshake;
  final double penalties;

  const FluxRouteScore({
    required this.total,
    required this.latency,
    required this.success,
    required this.stability,
    required this.throughput,
    required this.freshness,
    required this.handshake,
    required this.penalties,
  });
}

/// First-pass Dart adaptation of FLUX's documented multi-signal route ranking.
///
/// This deliberately keeps the weights explicit and testable. They are starting values for
/// Windows proxy mode, not claimed to be numerically identical to the Android implementation.
/// All probes must be completed outside this class; this class never treats a TCP handshake
/// as proof that a proxy works.
class FluxRouteScorer {
  static const double switchMargin = 0.15;
  static const Duration freshnessWindow = Duration(hours: 24);

  const FluxRouteScorer();

  FluxRouteScore score(
    FluxRouteMetrics metrics, {
    required DateTime now,
    bool usesFragment = false,
    bool hasVerifiedCertificate = true,
  }) {
    final samples = metrics.rttSamplesMs
        .where((sample) => sample.isFinite && sample > 0)
        .toList()
      ..sort();

    final median = _percentile(samples, 0.50);
    final p95 = _percentile(samples, 0.95);

    final latency = median == null ? 0 : _clamp(100 / (1 + median / 100));
    final success = metrics.successEwma * 100;
    final stability = median == null || p95 == null
        ? 0
        : _clamp(median / p95) * 100;
    final throughput = metrics.throughputMbps == null
        ? 0
        : _clamp(math.log(1 + math.max(0, metrics.throughputMbps!)) / math.log(101)) * 100;
    final age = metrics.lastVerifiedAt == null
        ? freshnessWindow.inSeconds.toDouble()
        : math.max(0, now.difference(metrics.lastVerifiedAt!).inSeconds).toDouble();
    final freshness = _clamp(1 - age / freshnessWindow.inSeconds) * 100;
    final handshake = metrics.handshakeMs == null
        ? 0
        : _clamp(100 / (1 + math.max(0, metrics.handshakeMs!) / 100));

    final penalties = metrics.consecutiveFailures * 12.0 +
        (usesFragment ? 5.0 : 0.0) +
        (hasVerifiedCertificate ? 0.0 : 30.0);

    final raw = latency * 0.30 +
        success * 0.25 +
        stability * 0.15 +
        throughput * 0.10 +
        freshness * 0.10 +
        handshake * 0.10;

    return FluxRouteScore(
      total: _clamp(raw - penalties),
      latency: latency,
      success: success,
      stability: stability,
      throughput: throughput,
      freshness: freshness,
      handshake: handshake,
      penalties: penalties,
    );
  }

  /// Require a 15% improvement before switching away from a working route.
  bool shouldSwitch({
    required double currentScore,
    required double candidateScore,
  }) {
    if (!currentScore.isFinite || !candidateScore.isFinite) return false;
    if (candidateScore <= 0) return false;
    if (currentScore <= 0) return true;
    return candidateScore >= currentScore * (1 + switchMargin);
  }

  static double? _percentile(List<double> sorted, double p) {
    if (sorted.isEmpty) return null;
    final index = ((sorted.length - 1) * p).round();
    return sorted[index];
  }

  static double _clamp(double value) => value.clamp(0.0, 100.0).toDouble();
}
