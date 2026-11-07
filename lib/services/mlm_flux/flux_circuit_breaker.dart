/// Per-route circuit breaker adapted from the documented FLUX policy.
///
/// Three consecutive failures open the route. Cooldown doubles from one minute up to six hours.
/// A successful end-to-end probe closes the breaker. Quarantine heuristics are intentionally
/// deferred until the Windows implementation has a defined, testable success/failure window.
class FluxCircuitBreaker {
  static const int failureThreshold = 3;
  static const Duration initialCooldown = Duration(minutes: 1);
  static const Duration maximumCooldown = Duration(hours: 6);

  int _consecutiveFailures = 0;
  DateTime? _openedUntil;

  int get consecutiveFailures => _consecutiveFailures;
  bool get isOpen => _openedUntil != null;
  DateTime? get openedUntil => _openedUntil;

  Duration get currentCooldown {
    if (_consecutiveFailures < failureThreshold) return Duration.zero;
    final exponent = _consecutiveFailures - failureThreshold;
    final multiplier = 1 << exponent.clamp(0, 20);
    final seconds = initialCooldown.inSeconds * multiplier;
    return Duration(seconds: seconds > maximumCooldown.inSeconds
        ? maximumCooldown.inSeconds
        : seconds);
  }

  bool canAttempt(DateTime now) =>
      _openedUntil == null || !now.isBefore(_openedUntil!);

  void recordFailure(DateTime now) {
    _consecutiveFailures++;
    if (_consecutiveFailures >= failureThreshold) {
      _openedUntil = now.add(currentCooldown);
    }
  }

  void recordSuccess() {
    _consecutiveFailures = 0;
    _openedUntil = null;
  }
}
