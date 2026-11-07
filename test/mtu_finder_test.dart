import 'package:flutter_test/flutter_test.dart';
import 'package:bpb/services/mtu_finder.dart';

void main() {
  group('MtuFinder.parseTargets', () {
    test('splits comma and whitespace separated IPv4 targets and de-duplicates', () {
      expect(
        MtuFinder.parseTargets('1.1.1.1, 8.8.8.8\\n1.1.1.1'),
        ['1.1.1.1', '8.8.8.8'],
      );
    });

    test('rejects an empty target list', () {
      expect(() => MtuFinder.parseTargets(' ,  '), throwsArgumentError);
    });

    test('rejects hostnames and IPv6 addresses', () {
      expect(() => MtuFinder.parseTargets('example.com'), throwsArgumentError);
      expect(() => MtuFinder.parseTargets('2606:4700:4700::1111'), throwsArgumentError);
    });
  });
}
