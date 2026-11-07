import 'package:flutter_test/flutter_test.dart';
import 'package:bpb/services/mlm_flux/flux_circuit_breaker.dart';
import 'package:bpb/services/mlm_flux/flux_route.dart';

void main() {
  group('FluxRouteScorer', () {
    const scorer = FluxRouteScorer();
    final now = DateTime.utc(2026, 11, 7, 12);

    test('ranks a recent, fast, stable route above a slow unstable route', () {
      final fast = scorer.score(
        FluxRouteMetrics(
          rttSamplesMs: [30, 31, 29, 32, 30],
          successEwma: 0.99,
          throughputMbps: 80,
          handshakeMs: 25,
          lastVerifiedAt: now.subtract(const Duration(minutes: 2)),
        ),
        now: now,
      );
      final slow = scorer.score(
        FluxRouteMetrics(
          rttSamplesMs: [300, 700, 400, 900, 350],
          successEwma: 0.65,
          throughputMbps: 2,
          handshakeMs: 450,
          lastVerifiedAt: now.subtract(const Duration(hours: 8)),
          consecutiveFailures: 2,
        ),
        now: now,
        usesFragment: true,
        hasVerifiedCertificate: false,
      );

      expect(fast.total, greaterThan(slow.total));
      expect(fast.total, inInclusiveRange(0, 100));
      expect(slow.total, inInclusiveRange(0, 100));
    });

    test('applies the documented 15 percent switch hysteresis', () {
      expect(
        scorer.shouldSwitch(currentScore: 80, candidateScore: 90),
        isFalse,
      );
      expect(
        scorer.shouldSwitch(currentScore: 80, candidateScore: 92),
        isTrue,
      );
      expect(
        scorer.shouldSwitch(currentScore: 0, candidateScore: 1),
        isTrue,
      );
    });

    test('rejects non-finite scores for switching', () {
      expect(
        scorer.shouldSwitch(currentScore: double.nan, candidateScore: 99),
        isFalse,
      );
    });

    test('candidate identity is separate from its secret-bearing endpoint', () {
      const candidate = FluxRouteCandidate(
        id: 'sha256:example-redacted-id',
        protocol: 'vless',
        host: 'node.example.invalid',
        port: 443,
      );
      expect(candidate.toString(), isNot(contains('uuid')));
      expect(candidate.id, startsWith('sha256:'));
    });
  });

  group('FluxCircuitBreaker', () {
    final start = DateTime.utc(2026, 11, 7, 12);

    test('opens after three failures and starts with a one-minute cooldown', () {
      final breaker = FluxCircuitBreaker();
      breaker.recordFailure(start);
      breaker.recordFailure(start);
      expect(breaker.canAttempt(start), isTrue);

      breaker.recordFailure(start);
      expect(breaker.isOpen, isTrue);
      expect(breaker.openedUntil, start.add(const Duration(minutes: 1)));
      expect(breaker.canAttempt(start), isFalse);
      expect(
        breaker.canAttempt(start.add(const Duration(minutes: 1))),
        isTrue,
      );
    });

    test('doubles cooldown on each further failed attempt, capped at six hours', () {
      final breaker = FluxCircuitBreaker();
      for (var i = 0; i < 3; i++) {
        breaker.recordFailure(start);
      }
      breaker.recordFailure(start.add(const Duration(minutes: 1)));
      expect(breaker.currentCooldown, const Duration(minutes: 2));

      for (var i = 0; i < 20; i++) {
        breaker.recordFailure(start.add(const Duration(minutes: 3 + i)));
      }
      expect(breaker.currentCooldown, const Duration(hours: 6));
    });

    test('a successful end-to-end probe resets the breaker', () {
      final breaker = FluxCircuitBreaker();
      for (var i = 0; i < 3; i++) {
        breaker.recordFailure(start);
      }
      breaker.recordSuccess();

      expect(breaker.consecutiveFailures, 0);
      expect(breaker.isOpen, isFalse);
      expect(breaker.canAttempt(start), isTrue);
    });
  });
}
