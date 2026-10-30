import 'dart:convert';

import 'package:clubins_frontend/ui/format.dart';
import 'package:clubins_frontend/ui/jwt.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/make_jwt.dart';

void main() {
  group('decodeJwt', () {
    test('decodes padded and unpadded segments', () {
      // {"alg":"RS256","kid":"k"} is 26 bytes, so its base64url keeps one
      // '=' — real issuers emit unpadded, the decoder must take both.
      final paddedHeader = base64Url.encode(utf8.encode(
        jsonEncode({'alg': 'RS256', 'kid': 'k'}),
      ));
      expect(paddedHeader, endsWith('='));
      final decoded = decodeJwt('$paddedHeader.${encodeSegment({'sub': 'user-1'})}.sig');
      expect(decoded.header, {'alg': 'RS256', 'kid': 'k'});
      expect(decoded.payload, {'sub': 'user-1'});
    });

    test('rejects a token without three parts', () {
      expect(
        () => decodeJwt('only.two'),
        throwsA(
          isA<FormatException>().having((e) => e.message, 'message',
              contains('expected 3 dot-separated parts')),
        ),
      );
    });

    test('rejects non-base64url segments', () {
      expect(
        () => decodeJwt('!!!"."!!!"."sig'),
        throwsA(
          isA<FormatException>()
              .having((e) => e.message, 'message', contains('header')),
        ),
      );
    });

    test('rejects a payload that is not a JSON object', () {
      final array = base64Url
          .encode(utf8.encode('[1,2]'))
          .replaceAll('=', '');
      expect(
        () => decodeJwt('${encodeSegment({'alg': 'RS256'})}.$array.sig'),
        throwsA(
          isA<FormatException>()
              .having((e) => e.message, 'message', contains('payload')),
        ),
      );
    });
  });

  group('formatTimestamp', () {
    test('renders local yyyy-MM-dd HH:mm', () {
      final formatted =
          formatTimestamp(DateTime.parse('2026-10-30T12:05:00Z'));
      // The test VM runs UTC, so local == UTC here; the form is fixed-width.
      expect(formatted, '2026-10-30 12:05');
    });
  });

  group('formatTemperature', () {
    test('keeps fractional values', () {
      expect(formatTemperature(21.5), '21.5 °C');
    });

    test('drops the decimal point on integral values', () {
      expect(formatTemperature(21), '21 °C');
      expect(formatTemperature(21.0), '21 °C');
    });
  });
}
