import 'dart:async';

import 'package:dio/dio.dart';
import 'package:dio_single_flight/dio_single_flight.dart';
import 'package:test/test.dart';

import 'helpers/fake_adapter.dart';

class _RecordingRequestHandler extends RequestInterceptorHandler {
  final _done = Completer<void>();
  RequestOptions? nextOptions;
  DioException? rejected;

  @override
  void next(RequestOptions requestOptions) {
    nextOptions = requestOptions;
    _done.complete();
  }

  @override
  void reject(
    DioException error, [
    bool callFollowingErrorInterceptor = false,
  ]) {
    rejected = error;
    _done.complete();
  }

  Future<void> get done => _done.future;
}

void main() {
  group('AuthRefreshInterceptor — core integration', () {
    late Dio dio;
    late FakeAdapter adapter;
    late MemoryTokenProvider provider;

    setUp(() {
      adapter = FakeAdapter();
      dio = Dio(BaseOptions(baseUrl: 'https://example.com'))
        ..httpClientAdapter = adapter;
      provider = MemoryTokenProvider(accessToken: 'A', refreshToken: 'rt1');
    });

    void stubAuthBehavior() {
      adapter.setHandler((options) async {
        final auth = options.headers['Authorization'];
        if (auth == 'Bearer A') {
          return jsonResponse({'error': 'unauthorized'}, status: 401);
        }
        return jsonResponse({'ok': true, 'token': auth});
      });
    }

    test('onRequest attaches Bearer token and stores kTokenKey', () async {
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
      adapter.setHandler(
        (options) async => jsonResponse({'echo': options.headers}),
      );

      final res = await dio.get<Map<String, dynamic>>('/protected');
      expect(res.data!['echo']['Authorization'], 'Bearer A');
      expect(adapter.calls.single.extra[kTokenKey], 'A');
      expect(refresherCalls, 0);
    });

    test(
      'onRequest with no token removes stale Authorization/kTokenKey',
      () async {
        provider.accessToken = null;
        final guard = AuthRefreshInterceptor(
          dio: dio,
          tokenProvider: provider,
          refresher: (refreshToken, refreshDio) async {
            return const AuthTokens(accessToken: 'B');
          },
        );

        final options = RequestOptions(path: '/protected')
          ..headers['Authorization'] = 'Bearer old'
          ..extra[kTokenKey] = 'old';

        final handler = _RecordingRequestHandler();
        guard.onRequest(options, handler);
        await handler.done;

        expect(handler.nextOptions, same(options));
        expect(options.headers.containsKey('Authorization'), isFalse);
        expect(options.extra.containsKey(kTokenKey), isFalse);
      },
    );

    test('shouldAttach false skips header injection', () async {
      dio.interceptors.add(
        AuthRefreshInterceptor(
          dio: dio,
          tokenProvider: provider,
          refresher: (refreshToken, refreshDio) async {
            return const AuthTokens(accessToken: 'B');
          },
          config: const AuthRefreshConfig(shouldAttach: _neverAttach),
        ),
      );
      adapter.setHandler(
        (options) async => jsonResponse({'echo': options.headers}),
      );

      final res = await dio.get<Map<String, dynamic>>('/login');
      expect(res.data!['echo'].containsKey('Authorization'), isFalse);
    });

    test(
      'single 401: refresh once, replay with new token, resolve 200',
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
        stubAuthBehavior();

        final res = await dio.get<Map<String, dynamic>>('/protected');
        expect(res.statusCode, 200);
        expect(res.data!['ok'], isTrue);
        expect(refresherCalls, 1);
        expect(provider.accessToken, 'B');
        expect(provider.refreshToken, 'rt2');
        expect(adapter.calls.length, 2, reason: 'original + replay');
        expect(adapter.calls[1].headers['Authorization'], 'Bearer B');
      },
    );

    test('5 concurrent 401s: one refresh, all resolve', () async {
      var refresherCalls = 0;
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
        ),
      );
      stubAuthBehavior();

      final results = List.generate(
        5,
        (_) => dio.get<Map<String, dynamic>>('/protected'),
      );
      // Let all five waiters reach onError and join the gated cycle.
      await pumpEventQueue(times: 30);
      refreshDone.complete();

      final responses = await Future.wait(results);
      expect(responses.every((r) => r.statusCode == 200), isTrue);
      expect(refresherCalls, 1);
      expect(adapter.calls.length, 10, reason: '5 originals + 5 replays');
    });

    test('refresh failure: all waiters rejected, onAuthFailed once', () async {
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
            throw const AuthRefreshException('refresh token revoked');
          },
          onAuthFailed: (_) => onAuthFailedCalls++,
        ),
      );
      adapter.setHandler(
        (options) async => jsonResponse({'error': 'unauthorized'}, status: 401),
      );

      final futures = List.generate(
        5,
        (_) => dio.get<Map<String, dynamic>>('/protected'),
      );
      await pumpEventQueue(times: 30);
      refreshDone.complete();

      final errors = await Future.wait(futures.map(outcome));
      for (final e in errors) {
        expect(e, isA<DioException>());
        final de = e as DioException;
        expect(de.error, isA<AuthRefreshException>());
        expect(
          (de.error! as AuthRefreshException).message,
          'refresh token revoked',
        );
      }
      expect(refresherCalls, 1);
      expect(
        onAuthFailedCalls,
        1,
        reason: 'onAuthFailed must fire once per cycle, not per waiter',
      );
    });

    test('onAuthFailed throwing does not break rejection flow', () async {
      final uncaught = <Object>[];
      await runZonedGuarded(() async {
        dio.interceptors.add(
          AuthRefreshInterceptor(
            dio: dio,
            tokenProvider: provider,
            refresher: (refreshToken, refreshDio) async {
              throw const AuthRefreshException('refresh token revoked');
            },
            onAuthFailed: (cause) => throw Exception('logout UI crashed'),
          ),
        );
        adapter.setHandler(
          (options) async => jsonResponse({'e': 1}, status: 401),
        );

        final e = await outcome(dio.get<Map<String, dynamic>>('/protected'));
        expect(e, isA<DioException>());
        expect((e as DioException).error, isA<AuthRefreshException>());
        await pumpEventQueue(times: 20);
      }, (e, s) => uncaught.add(e));
      await pumpEventQueue(times: 20);
      expect(uncaught, isEmpty);
    });

    test('non-401 errors pass through without refresh', () async {
      var refresherCalls = 0;
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
      adapter.setHandler(
        (options) async => jsonResponse({'error': 'boom'}, status: 500),
      );

      final e = await outcome(dio.get<Map<String, dynamic>>('/protected'));
      expect(e, isA<DioException>());
      expect((e as DioException).response?.statusCode, 500);
      expect(refresherCalls, 0);
    });

    test('retried request 401 again: rejected, no infinite loop', () async {
      var refresherCalls = 0;
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
      adapter.setHandler(
        (options) async => jsonResponse({'error': 'unauthorized'}, status: 401),
      );

      final e = await outcome(dio.get<Map<String, dynamic>>('/protected'));
      expect(e, isA<DioException>());
      final de = e as DioException;
      expect(de.response?.statusCode, 401);
      expect(
        de.requestOptions.extra[kRetryKey],
        isTrue,
        reason: 'the delivered error is the replayed (retry-flagged) one',
      );
      expect(refresherCalls, 1);
      expect(adapter.calls.length, 2);
    });

    test('no token sent: 401 passes through, no refresh', () async {
      var refresherCalls = 0;
      provider.accessToken = null;
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
      adapter.setHandler(
        (options) async => jsonResponse({'error': 'unauthorized'}, status: 401),
      );

      final e = await outcome(dio.get<Map<String, dynamic>>('/login'));
      expect(e, isA<DioException>());
      final de = e as DioException;
      expect(de.response?.statusCode, 401);
      expect(
        de.error,
        isNot(isA<AuthRefreshException>()),
        reason: 'genuine 401, not a refresh failure',
      );
      expect(refresherCalls, 0);
    });

    test(
      'refresh times out: waiter rejected, setTokens never called',
      () async {
        var refresherCalls = 0;
        final refresherGate = Completer<void>();
        var onAuthFailedCalls = 0;
        dio.interceptors.add(
          AuthRefreshInterceptor(
            dio: dio,
            tokenProvider: provider,
            config:
                const AuthRefreshConfig(refreshTimeout: Duration(seconds: 1)),
            refresher: (refreshToken, refreshDio) async {
              refresherCalls++;
              await refresherGate.future;
              return const AuthTokens(
                accessToken: 'late',
                refreshToken: 'late',
              );
            },
            onAuthFailed: (_) => onAuthFailedCalls++,
          ),
        );
        adapter.setHandler(
          (options) async => jsonResponse({'e': 1}, status: 401),
        );

        final future = dio.get<Map<String, dynamic>>('/protected');
        final e = await outcome(future) as DioException;
        final age = e.error! as AuthRefreshException;
        expect(age.message, contains('timed out'));
        expect(age.cause, isA<TimeoutException>());
        expect(age.retryable, isTrue, reason: 'timeouts are transient');
        expect(
          onAuthFailedCalls,
          0,
          reason: 'timeouts never call onAuthFailed',
        );

        // The refresher completes late; the abandoned flag must discard it.
        refresherGate.complete();
        await pumpEventQueue(times: 30);
        expect(
          provider.setTokensCalls,
          0,
          reason: 'late refresher result must be discarded',
        );
        expect(provider.accessToken, 'A');
        expect(refresherCalls, 1);
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test(
      'logout during refresh: session changed, setTokens not called',
      () async {
        final refreshDone = Completer<void>();
        dio.interceptors.add(
          AuthRefreshInterceptor(
            dio: dio,
            tokenProvider: provider,
            refresher: (refreshToken, refreshDio) async {
              await refreshDone.future;
              // Logout happens while the refresh is in-flight.
              await provider.clear();
              return const AuthTokens(accessToken: 'stale', refreshToken: 'x');
            },
          ),
        );
        adapter.setHandler(
          (options) async => jsonResponse({'e': 1}, status: 401),
        );

        final future = dio.get<Map<String, dynamic>>('/protected');
        await pumpEventQueue(times: 10);
        refreshDone.complete();

        final e = await outcome(future) as DioException;
        final age = e.error! as AuthRefreshException;
        expect(age.message, 'session changed during refresh');
        expect(provider.setTokensCalls, 0);
      },
    );

    test(
      'logout-then-login during refresh: new tokens not overwritten',
      () async {
        final refreshDone = Completer<void>();
        dio.interceptors.add(
          AuthRefreshInterceptor(
            dio: dio,
            tokenProvider: provider,
            refresher: (refreshToken, refreshDio) async {
              await refreshDone.future;
              return const AuthTokens(
                accessToken: 'staleA',
                refreshToken: 'rt3',
              );
            },
          ),
        );
        adapter.setHandler(
          (options) async => jsonResponse({'e': 1}, status: 401),
        );

        final future = dio.get<Map<String, dynamic>>('/protected');
        await pumpEventQueue(times: 10);
        // Logout + fresh login while the refresh is in-flight.
        await provider.clear();
        await provider.setTokens(
          const AuthTokens(accessToken: 'newA', refreshToken: 'rt2'),
        );
        refreshDone.complete();

        final e = await outcome(future) as DioException;
        expect(
          (e.error! as AuthRefreshException).message,
          'session changed during refresh',
        );

        await pumpEventQueue(times: 30);
        expect(
          provider.accessToken,
          'newA',
          reason: 'stale refresh result must not overwrite the new session',
        );
        expect(provider.refreshToken, 'rt2');
        expect(
          provider.setTokensCalls,
          1,
          reason: 'only the login persisted tokens, never the guard',
        );
      },
    );

    test('null refresh token at start: refresher never invoked', () async {
      var refresherCalls = 0;
      provider.refreshToken = null;
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
      adapter.setHandler(
        (options) async => jsonResponse({'e': 1}, status: 401),
      );

      final e = await outcome(dio.get<Map<String, dynamic>>('/protected'));
      final age = (e as DioException).error! as AuthRefreshException;
      expect(age.message, contains('no refresh token'));
      expect(refresherCalls, 0);
    });

    test(
      'refreshDio hits the shared adapter; no interceptor recursion',
      () async {
        var refresherCalls = 0;
        var refreshEndpointCalls = 0;
        adapter.setHandler((options) async {
          if (options.path == '/auth/refresh') {
            refreshEndpointCalls++;
            return jsonResponse({'accessToken': 'B', 'refreshToken': 'rt2'});
          }
          final auth = options.headers['Authorization'];
          if (auth == 'Bearer A') {
            return jsonResponse({'error': 'unauthorized'}, status: 401);
          }
          return jsonResponse({'ok': true});
        });

        dio.interceptors.add(
          AuthRefreshInterceptor(
            dio: dio,
            tokenProvider: provider,
            refresher: (refreshToken, refreshDio) async {
              refresherCalls++;
              final res = await refreshDio.post<Map<String, dynamic>>(
                '/auth/refresh',
                data: {'refreshToken': refreshToken},
              );
              return AuthTokens(
                accessToken: res.data!['accessToken'] as String,
                refreshToken: res.data!['refreshToken'] as String?,
              );
            },
          ),
        );

        final res = await dio.get<Map<String, dynamic>>('/protected');
        expect(res.data!['ok'], isTrue);
        expect(refresherCalls, 1);
        expect(refreshEndpointCalls, 1);
        expect(adapter.calls.any((c) => c.path == '/auth/refresh'), isTrue);
      },
    );
  });
}

bool _neverAttach(RequestOptions req) => false;
