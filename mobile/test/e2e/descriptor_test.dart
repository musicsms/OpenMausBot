import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:nibble/core/e2e/credentials.dart';
import 'package:nibble/core/e2e/descriptor.dart';

void main() {
  group('E2E Descriptor parsing', () {
    test('parses valid self-hosted descriptor from QR', () {
      final desc = E2EDescriptor.parseJson({
        'v': 1,
        'k': 'BJiFmi3bzpQUayMJErl6eqt24mUOvHEUR6uzutPTHfundIgyZxs3bSzUMydGOfgbWdwQshIyzzlMWqxMkNHnmd0',
        'h': 'lz81isB3BuNV6rHgYgG3Wg',
        'r': ['relay.example.com'],
      });
      expect(desc.version, equals(1));
      expect(desc.relayNodes, equals(['relay.example.com']));
      expect(desc.hasRelay, isTrue);
      expect(desc.k, equals('BJiFmi3bzpQUayMJErl6eqt24mUOvHEUR6uzutPTHfundIgyZxs3bSzUMydGOfgbWdwQshIyzzlMWqxMkNHnmd0'));
      expect(desc.h, equals('lz81isB3BuNV6rHgYgG3Wg'));
      expect(desc.transportPublicKey.length, equals(65));
      expect(desc.hostId!.length, equals(16));
    });

    test('parses valid descriptor without relay endpoints', () {
      final desc = E2EDescriptor.parseJson({
        'v': 1,
        'k': 'BJiFmi3bzpQUayMJErl6eqt24mUOvHEUR6uzutPTHfundIgyZxs3bSzUMydGOfgbWdwQshIyzzlMWqxMkNHnmd0',
      });
      expect(desc.version, equals(1));
      expect(desc.relayNodes, isEmpty);
      expect(desc.hasRelay, isFalse);
      expect(desc.hostId, isNull);
    });

    test('rejects descriptors with invalid hosts or mismatched relay fields', () {
      expect(() => E2EDescriptor.parseJson({'v': 1, 'k': 'invalid'}), throwsA(isA<FormatException>()));
      expect(
        () => E2EDescriptor.parseJson({
          'v': 1,
          'k': 'BJiFmi3bzpQUayMJErl6eqt24mUOvHEUR6uzutPTHfundIgyZxs3bSzUMydGOfgbWdwQshIyzzlMWqxMkNHnmd0',
          'h': 'lz81isB3BuNV6rHgYgG3Wg',
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => E2EDescriptor.parseJson({
          'v': 1,
          'k': 'BJiFmi3bzpQUayMJErl6eqt24mUOvHEUR6uzutPTHfundIgyZxs3bSzUMydGOfgbWdwQshIyzzlMWqxMkNHnmd0',
          'r': ['relay.example.com'],
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects unsupported versions', () {
      expect(
        () => E2EDescriptor.parseJson({
          'v': 2,
          'k': 'BJiFmi3bzpQUayMJErl6eqt24mUOvHEUR6uzutPTHfundIgyZxs3bSzUMydGOfgbWdwQshIyzzlMWqxMkNHnmd0',
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects relay lists with 0 or more than 4 nodes', () {
      expect(
        () => E2EDescriptor.parseJson({
          'v': 1,
          'k': 'BJiFmi3bzpQUayMJErl6eqt24mUOvHEUR6uzutPTHfundIgyZxs3bSzUMydGOfgbWdwQshIyzzlMWqxMkNHnmd0',
          'h': 'lz81isB3BuNV6rHgYgG3Wg',
          'r': [],
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => E2EDescriptor.parseJson({
          'v': 1,
          'k': 'BJiFmi3bzpQUayMJErl6eqt24mUOvHEUR6uzutPTHfundIgyZxs3bSzUMydGOfgbWdwQshIyzzlMWqxMkNHnmd0',
          'h': 'lz81isB3BuNV6rHgYgG3Wg',
          'r': [
            'r1.example.com',
            'r2.example.com',
            'r3.example.com',
            'r4.example.com',
            'r5.example.com',
          ],
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('parses from base64url encoded string and raw JSON string', () {
      final jsonMap = {
        'v': 1,
        'k': 'BJiFmi3bzpQUayMJErl6eqt24mUOvHEUR6uzutPTHfundIgyZxs3bSzUMydGOfgbWdwQshIyzzlMWqxMkNHnmd0',
        'h': 'lz81isB3BuNV6rHgYgG3Wg',
        'r': ['relay.example.com'],
      };
      final jsonStr = jsonEncode(jsonMap);
      final b64uStr = b64u(Uint8List.fromList(utf8.encode(jsonStr)));

      final descFromB64u = E2EDescriptor.parse(b64uStr);
      expect(descFromB64u.version, equals(1));
      expect(descFromB64u.relayNodes, equals(['relay.example.com']));

      final descFromJson = E2EDescriptor.parse(jsonStr);
      expect(descFromJson.version, equals(1));
      expect(descFromJson.relayNodes, equals(['relay.example.com']));
    });

    test('validates all self-hosted vector hosts from self-hosted.json', () {
      final vectorFile = File('../companion/src/e2e/vectors/self-hosted.json');
      if (vectorFile.existsSync()) {
        final parsed = jsonDecode(vectorFile.readAsStringSync()) as Map<String, dynamic>;
        final hosts = (parsed['hosts'] as List).cast<Map<String, dynamic>>();
        for (final item in hosts) {
          final host = item['host'] as String;
          final expectedValid = item['valid'] as bool;
          expect(
            isValidRelayHost(host),
            equals(expectedValid),
            reason: 'Host validation mismatch for: "$host"',
          );
        }
      }
    });

    test('serializes to JSON matching original shape', () {
      final desc = E2EDescriptor.parseJson({
        'v': 1,
        'k': 'BJiFmi3bzpQUayMJErl6eqt24mUOvHEUR6uzutPTHfundIgyZxs3bSzUMydGOfgbWdwQshIyzzlMWqxMkNHnmd0',
        'h': 'lz81isB3BuNV6rHgYgG3Wg',
        'r': ['relay.example.com'],
        'routes': 'any',
      });
      final json = desc.toJson();
      expect(json['v'], equals(1));
      expect(json['k'], equals('BJiFmi3bzpQUayMJErl6eqt24mUOvHEUR6uzutPTHfundIgyZxs3bSzUMydGOfgbWdwQshIyzzlMWqxMkNHnmd0'));
      expect(json['h'], equals('lz81isB3BuNV6rHgYgG3Wg'));
      expect(json['r'], equals(['relay.example.com']));
      expect(json['routes'], equals('any'));
    });
  });
}
