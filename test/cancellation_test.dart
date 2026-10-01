import 'dart:async';

import 'package:dio/dio.dart';
import 'package:dio_single_flight/dio_single_flight.dart';
import 'package:test/test.dart';

import 'helpers/fake_adapter.dart';

void main() {
  group('cancellation', () {
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
        'waiter cancelled mid-refresh: rejects immediately, refresh continues '
        'for the other waiter', () async {
      var refresherCalls = 0;
      var onAuthFailedCalls = 0;
      final refreshDone = Completer<void>();
      dio.interceptors.add(
        AuthRefreshInterceptor(
          dio: dio,
          tokenProvider: provider,
          refresher: (refreshToken, refreshDio) async {
            refresherCalls++;
            await refreshDone.future;
            return const AuthTokens(accessToken: 'B', refreshToken: 'rt2');
          },
          onAuthFailed: (_) => onAuthFailedCalls++,
        ),
      );

      adapter.setHandler((options) async {
        final auth = options.headers['Authorization'];
        if (auth == 'Bearer A') {
          return jsonResponse({'error': 'unauthorized'}, status: 401);
        }
        return jsonResponse({'ok': true});
      });

      final tokenA = CancelToken();
      final tokenB = CancelToken();

      final futureA = dio.get<Map<String, dynamic>>(
        '/protected',
        cancelToken: tokenA,
      );
      final futureB = dio.get<Map<String, dynamic>>(
        '/protected',
        cancelToken: tokenB,
      );

      // Both 401s arrive; the refresh is gated. Cancel B while it waits.
      await pumpEventQueue(times: 30);
      tokenB.cancel('user navigated away');

      final e = await outcome(futureB) as DioException;
      expect(e.type, DioExceptionType.cancel);

      // Releasing the gate finishes the refresh for the remaining waiter.
      refreshDone.complete();
      final resA = await futureA;
      expect(resA.statusCode, 200);
      expect(resA.data!['ok'], isTrue);
      expect(
        refresherCalls,
        1,
        reason: 'cancelling one waiter must not abort the refresh',
      );
      expect(onAuthFailedCalls, 0, reason: 'the cycle succeeded');
      expect(provider.accessToken, 'B');
    });

    test(
      'request cancelled before onError: no refresh is ever started',
      () async {
        var refresherCalls = 0;
        final adapterGate = Completer<void>();
        dio.interceptors.add(
          AuthRefreshInterceptor(
            dio: dio,
            tokenProvider: provider,
            refresher: (refreshToken, refreshDio) async {
              refresherCalls++;
              return const AuthTokens(accessToken: 'B');
            },
          ),
        );

        // The adapter never answers until the gate opens; the request is
        // cancelled while it hangs in the adapter.
        adapter.setHandler((options) async {
          await adapterGate.future;
          return jsonResponse({'error': 'unauthorized'}, status: 401);
        });

        final token = CancelToken();
        final future = dio.get<Map<String, dynamic>>(
          '/protected',
          cancelToken: token,
        );

        await pumpEventQueue(times: 10);
        token.cancel('changed my mind');

        final e = await outcome(future) as DioException;
        expect(e.type, DioExceptionType.cancel);
        expect(
          refresherCalls,
          0,
          reason: 'a cancelled request must never enter the coordinator',
        );
      },
    );

    test(
      'cancellation during replay: waiter receives the cancel error',
      () async {
        var refresherCalls = 0;
        final replayGate = Completer<void>();
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
          // The replay hangs in the adapter until the gate opens.
          await replayGate.future;
          return jsonResponse({'ok': true});
        });

        final token = CancelToken();
        final future = dio.get<Map<String, dynamic>>(
          '/protected',
          cancelToken: token,
        );

        // The replay must be dispatched before the cancellation lands.
        await pumpEventQueue(times: 30);
        expect(adapter.calls.length, 2);
        token.cancel('replay aborted');

        final e = await outcome(future) as DioException;
        expect(e.type, DioExceptionType.cancel);
        expect(
          adapter.calls.length,
          2,
          reason: 'the cancel landed after the replay was dispatched',
        );
        expect(adapter.calls[1].headers['Authorization'], 'Bearer B');
        expect(refresherCalls, 1);
      },
    );
  });
}
