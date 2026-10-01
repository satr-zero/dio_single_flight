import 'package:dio_single_flight/dio_single_flight.dart';
import 'package:test/test.dart';

void main() {
  group('MemoryTokenProvider', () {
    test('starts empty', () async {
      final p = MemoryTokenProvider();
      expect(await p.getAccessToken(), isNull);
      expect(await p.getRefreshToken(), isNull);
    });

    test('starts with initial values', () async {
      final p = MemoryTokenProvider(accessToken: 'a', refreshToken: 'r');
      expect(await p.getAccessToken(), 'a');
      expect(await p.getRefreshToken(), 'r');
    });

    test('setTokens persists both tokens and increments counter', () async {
      final p = MemoryTokenProvider();
      await p.setTokens(
        const AuthTokens(accessToken: 'a2', refreshToken: 'r2'),
      );
      expect(await p.getAccessToken(), 'a2');
      expect(await p.getRefreshToken(), 'r2');
      expect(p.setTokensCalls, 1);
    });

    test('setTokens with null refreshToken keeps previous one', () async {
      final p = MemoryTokenProvider(refreshToken: 'r1');
      await p.setTokens(const AuthTokens(accessToken: 'a2'));
      expect(await p.getAccessToken(), 'a2');
      expect(
        await p.getRefreshToken(),
        'r1',
        reason: 'non-rotating backends keep the old refresh token',
      );
    });

    test('clear removes everything and increments counter', () async {
      final p = MemoryTokenProvider(accessToken: 'a', refreshToken: 'r');
      await p.clear();
      expect(await p.getAccessToken(), isNull);
      expect(await p.getRefreshToken(), isNull);
      expect(p.clearCalls, 1);
    });
  });

  group('AuthTokens', () {
    test('holds values', () {
      const t = AuthTokens(accessToken: 'a', refreshToken: 'r');
      expect(t.accessToken, 'a');
      expect(t.refreshToken, 'r');
    });
  });
}
