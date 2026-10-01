import 'dart:async';

import 'package:dio/dio.dart';
import 'package:dio_single_flight/dio_single_flight.dart';
import 'package:test/test.dart';

import 'helpers/fake_adapter.dart';

void main() {
  group('race token guard', () {
    late Dio dio;
    late FakeAdapter adapter;
    late MemoryTokenProvider provider;

    setUp(() {
      adapter = FakeAdapter();
      dio = Dio(BaseOptions(baseUrl: 'https://example.com'))
        ..httpClientAdapter = adapter;
      provider = MemoryTokenProvider(accessToken: 'A', refreshToken: 'rt1');
    });

    test(
      'late 401 after an external refresh: replays without a second refresh',
      () async {
        var refresherCalls = 0;
        dio.interceptors.add(
          AuthRefreshInterceptor(
            dio: dio,
            tokenProvider: provider,
            refresher: (refreshToken, refreshDio) async {
              refresherCalls++;
              return const AuthTokens(accessToken: 'B', refreshToken: 'rt2');
            },
          ),
        );

        // The request goes out with token A; the adapter holds its 401 back.
        final first401Gate = Completer<void>();
        adapter.setHandler((options) async {
          final auth = options.headers['Authorization'];
          if (auth == 'Bearer A') {
            await first401Gate.future;
            return jsonResponse({'error': 'unauthorized'}, status: 401);
          }
          return jsonResponse({'ok': true, 'token': auth});
        });

        final future = dio.get<Map<String, dynamic>>('/protected');
        await pumpEventQueue(times: 10);

        // An external refresh (another tab / push-triggered) rotates tokens
        // while the request is still in flight.
        await provider.setTokens(
          const AuthTokens(accessToken: 'B', refreshToken: 'rt2'),
        );
        first401Gate.complete();

        final res = await future;
        expect(res.statusCode, 200);
        expect(
          res.data!['token'],
          'Bearer B',
          reason: 'replayed with the current token',
        );
        expect(
          refresherCalls,
          0,
          reason: 'token already differs — refresh must be skipped entirely',
        );
        expect(
          adapter.calls.length,
          2,
          reason: 'original + replay, no refresh',
        );
      },
    );

    test('sent token equals current: refresh runs normally', () async {
      var refresherCalls = 0;
      dio.interceptors.add(
        AuthRefreshInterceptor(
          dio: dio,
          tokenProvider: provider,
          refresher: (refreshToken, refreshDio) async {
            refresherCalls++;
            return const AuthTokens(accessToken: 'B', refreshToken: 'rt2');
          },
        ),
      );

      adapter.setHandler((options) async {
        final auth = options.headers['Authorization'];
        if (auth == 'Bearer A') {
          return jsonResponse({'error': 'unauthorized'}, status: 401);
        }
        return jsonResponse({'ok': true});
      });

      final res = await dio.get<Map<String, dynamic>>('/protected');
      expect(res.data!['ok'], isTrue);
      expect(refresherCalls, 1, reason: 'stale token — refresh is required');
    });

    test(
      'concurrent burst + late straggler: exactly one refresh for all three',
      () async {
        var refresherCalls = 0;
        final refreshDone = Completer<void>();
        final stragglerGate = Completer<void>();
        dio.interceptors.add(
          AuthRefreshInterceptor(
            dio: dio,
            tokenProvider: provider,
            refresher: (refreshToken, refreshDio) async {
              refresherCalls++;
              await refreshDone.future;
              return const AuthTokens(accessToken: 'B', refreshToken: 'rt2');
            },
          ),
        );

        adapter.setHandler((options) async {
          if (options.extra['straggler'] == true &&
              options.headers['Authorization'] == 'Bearer A') {
            // Sent with token A before the refresh; its 401 arrives late.
            await stragglerGate.future;
            return jsonResponse({'error': 'unauthorized'}, status: 401);
          }
          final auth = options.headers['Authorization'];
          if (auth == 'Bearer A') {
            return jsonResponse({'error': 'unauthorized'}, status: 401);
          }
          return jsonResponse({'ok': true, 'token': auth});
        });

        // Burst of two, blocked inside the gated refresh.
        final burst = [
          dio.get<Map<String, dynamic>>('/protected'),
          dio.get<Map<String, dynamic>>('/protected'),
        ];
        await pumpEventQueue(times: 10);

        // Straggler dispatched with the still-current token A; its 401 is
        // held back by the adapter until the refresh has completed.
        final straggler = dio.get<Map<String, dynamic>>(
          '/protected',
          options: Options(extra: {'straggler': true}),
        );

        refreshDone.complete();
        final burstResponses = await Future.wait(burst);
        expect(burstResponses.map((r) => r.statusCode), everyElement(200));

        // The straggler's 401 arrives after the refresh completed.
        stragglerGate.complete();
        final res = await straggler;
        expect(res.statusCode, 200);
        expect(res.data!['token'], 'Bearer B');
        expect(
          refresherCalls,
          1,
          reason: 'the late straggler 401 must not trigger a second refresh',
        );
      },
    );
  });
}
