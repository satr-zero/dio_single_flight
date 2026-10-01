import 'dart:async';

import 'package:dio/dio.dart';
import 'package:dio_single_flight/dio_single_flight.dart';
import 'package:test/test.dart';

import 'helpers/fake_adapter.dart';

/// Refresher test double: the FIRST call blocks until [release] so tests
/// can coordinate waiters deterministically; later calls resolve instantly
/// with the current [failWith] / [succeedWith].
class GatedRefresher {
  final started = Completer<void>();
  final _gate = Completer<void>();
  int calls = 0;

  Object? failWith;
  AuthTokens? succeedWith;

  Future<AuthTokens> call(String refreshToken, Dio refreshDio) {
    calls++;
    if (!started.isCompleted) started.complete();
    if (calls > 1) {
      return Future<AuthTokens>(_result);
    }
    return _gate.future.then((_) => _result());
  }

  AuthTokens _result() {
    final failure = failWith;
    if (failure != null) throw failure;
    return succeedWith!;
  }

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }
}

/// Token provider whose SECOND `getRefreshToken` call blocks until
/// [releaseRead] — used to let the refresh timeout fire during the
/// session re-read, right before `setTokens`.
class _SecondReadGatedProvider implements TokenProvider {
  _SecondReadGatedProvider(this._inner);

  final MemoryTokenProvider _inner;
  final _readGate = Completer<void>();
  int refreshReads = 0;

  @override
  Future<String?> getRefreshToken() async {
    refreshReads++;
    if (refreshReads == 2) {
      await _readGate.future;
    }
    return _inner.getRefreshToken();
  }

  void releaseRead() {
    if (!_readGate.isCompleted) _readGate.complete();
  }

  @override
  Future<String?> getAccessToken() => _inner.getAccessToken();

  @override
  Future<void> setTokens(AuthTokens tokens) => _inner.setTokens(tokens);

  @override
  Future<void> clear() => _inner.clear();
}

class _RecordingErrorHandler extends ErrorInterceptorHandler {
  int resolveCalls = 0;
  int rejectCalls = 0;
  int nextCalls = 0;

  @override
  void resolve(
    Response response, [
    bool callFollowingResponseInterceptor = false,
  ]) {
    resolveCalls++;
  }

  @override
  void reject(
    DioException error, [
    bool callFollowingErrorInterceptor = false,
  ]) {
    rejectCalls++;
  }

  @override
  void next(DioException error) {
    nextCalls++;
  }
}

DioException _sent401(RequestOptions options) {
  return DioException(
    requestOptions: options,
    response: Response<dynamic>(requestOptions: options, statusCode: 401),
    type: DioExceptionType.badResponse,
  );
}

RequestOptions _sentWith(String token) {
  return RequestOptions(path: '/protected', baseUrl: 'https://example.com')
    ..extra[kTokenKey] = token;
}

/// Builds a [DioException] as a refresher would throw it when the refresh
/// endpoint answers with [status].
DioException _refreshEndpointError(int status) {
  final options = RequestOptions(path: '/auth/refresh');
  return DioException(
    requestOptions: options,
    response: Response<dynamic>(
      requestOptions: options,
      statusCode: status,
      data: {'error': 'refresh rejected'},
    ),
    type: DioExceptionType.badResponse,
  );
}

void main() {
  group('AuthRefreshInterceptor — failure memo', () {
    late Dio dio;
    late FakeAdapter adapter;
    late MemoryTokenProvider provider;

    setUp(() {
      adapter = FakeAdapter();
      dio = Dio(BaseOptions(baseUrl: 'https://example.com'))
        ..httpClientAdapter = adapter;
      provider = MemoryTokenProvider(accessToken: 'A', refreshToken: 'rt1');
      adapter.setHandler((options) async {
        final auth = options.headers['Authorization'];
        if (auth == 'Bearer A') {
          return jsonResponse({'error': 'unauthorized'}, status: 401);
        }
        return jsonResponse({'ok': true, 'token': auth});
      });
    });

    test(
        'staggered waves: second wave after a terminal failure is rejected '
        'from the memo — refresher and onAuthFailed exactly once', () async {
      final refresher = GatedRefresher()
        ..failWith = const AuthRefreshException('refresh token revoked');
      var onAuthFailedCalls = 0;
      dio.interceptors.add(
        AuthRefreshInterceptor(
          dio: dio,
          tokenProvider: provider,
          refresher: refresher.call,
          onAuthFailed: (_) => onAuthFailedCalls++,
        ),
      );

      // First wave of two, blocked inside the gated refresh.
      final wave1 = [
        dio.get<Map<String, dynamic>>('/protected'),
        dio.get<Map<String, dynamic>>('/protected'),
      ];
      await refresher.started.future;
      await pumpEventQueue(times: 20);
      refresher.release();

      for (final f in wave1) {
        final e = await outcome(f) as DioException;
        expect(
          (e.error! as AuthRefreshException).message,
          'refresh token revoked',
        );
      }
      expect(refresher.calls, 1);
      expect(onAuthFailedCalls, 1);

      // Second wave arrives after the first cycle already failed.
      final wave2 = [
        dio.get<Map<String, dynamic>>('/protected'),
        dio.get<Map<String, dynamic>>('/protected'),
      ];
      for (final f in wave2) {
        final e = await outcome(f) as DioException;
        expect(
          (e.error! as AuthRefreshException).message,
          'refresh token revoked',
        );
      }
      expect(refresher.calls, 1, reason: 'memo must suppress new cycles');
      expect(
        onAuthFailedCalls,
        1,
        reason: 'memo rejections must not re-fire onAuthFailed',
      );
    });

    test(
        'stragglers after logout: session-ended path, no extra refresh or '
        'onAuthFailed', () async {
      final stragglerGate = Completer<void>();
      adapter.setHandler((options) async {
        if (options.extra['straggler'] == true) {
          // The straggler's 401 is delivered only after the gate opens —
          // by then the user has logged out.
          await stragglerGate.future;
          return jsonResponse({'error': 'unauthorized'}, status: 401);
        }
        final auth = options.headers['Authorization'];
        if (auth == 'Bearer A') {
          return jsonResponse({'error': 'unauthorized'}, status: 401);
        }
        return jsonResponse({'ok': true, 'token': auth});
      });

      final refresher = GatedRefresher()
        ..succeedWith = const AuthTokens(
          accessToken: 'stale',
          refreshToken: 'x',
        );
      var onAuthFailedCalls = 0;
      dio.interceptors.add(
        AuthRefreshInterceptor(
          dio: dio,
          tokenProvider: provider,
          refresher: refresher.call,
          onAuthFailed: (_) => onAuthFailedCalls++,
        ),
      );

      // First request: refresh in-flight and gated.
      final first = dio.get<Map<String, dynamic>>('/protected');
      await refresher.started.future;

      // Straggler dispatched while token A is still current (it is sent
      // with A), but its 401 response is held back by the adapter gate.
      final straggler = dio.get<Map<String, dynamic>>(
        '/protected',
        options: Options(extra: {'straggler': true}),
      );
      await pumpEventQueue(times: 20);

      // Logout while the refresh is in-flight, then let the cycle finish.
      await provider.clear();
      refresher.release();

      final e = await outcome(first) as DioException;
      expect(
        (e.error! as AuthRefreshException).message,
        'session changed during refresh',
      );
      expect(onAuthFailedCalls, 1);
      expect(refresher.calls, 1);

      // Now the straggler's 401 finally arrives — after the logout.
      stragglerGate.complete();
      final stragglerError = await outcome(straggler) as DioException;
      final age = stragglerError.error! as AuthRefreshException;
      expect(age.message, contains('session ended'));
      expect(refresher.calls, 1, reason: 'no refresh for stragglers');
      expect(onAuthFailedCalls, 1, reason: 'no onAuthFailed for stragglers');
    });

    test('transient failure: a later 401 starts a fresh refresh', () async {
      final refresher = GatedRefresher()
        ..failWith = DioException(
          requestOptions: RequestOptions(path: '/auth/refresh'),
          type: DioExceptionType.connectionError,
        );
      var onAuthFailedCalls = 0;
      dio.interceptors.add(
        AuthRefreshInterceptor(
          dio: dio,
          tokenProvider: provider,
          refresher: refresher.call,
          onAuthFailed: (_) => onAuthFailedCalls++,
        ),
      );

      final first = dio.get<Map<String, dynamic>>('/protected');
      await refresher.started.future;
      refresher.release();

      final e = await outcome(first) as DioException;
      final age = e.error! as AuthRefreshException;
      expect(age.cause, isA<DioException>());
      expect(
        age.retryable,
        isTrue,
        reason: 'transient failures reject with retryable: true',
      );
      expect(
        onAuthFailedCalls,
        0,
        reason: 'transient failures never call onAuthFailed',
      );

      // Not memoized: the next 401 gets a brand-new (successful) cycle.
      refresher
        ..failWith = null
        ..succeedWith = const AuthTokens(accessToken: 'B', refreshToken: 'rt2');
      final res = await dio.get<Map<String, dynamic>>('/protected');
      expect(res.statusCode, 200);
      expect(refresher.calls, 2, reason: 'transient failures retry');
      expect(onAuthFailedCalls, 0);
    });

    test('after a refresh timeout, a new 401 starts a fresh refresh', () async {
      final refresher = GatedRefresher();
      var onAuthFailedCalls = 0;
      dio.interceptors.add(
        AuthRefreshInterceptor(
          dio: dio,
          tokenProvider: provider,
          refresher: refresher.call,
          config: const AuthRefreshConfig(refreshTimeout: Duration(seconds: 1)),
          onAuthFailed: (_) => onAuthFailedCalls++,
        ),
      );

      // First request: the refresher stays gated, so the 1 s timeout fires.
      final first = dio.get<Map<String, dynamic>>('/protected');
      final e = await outcome(first) as DioException;
      final age = e.error! as AuthRefreshException;
      expect(age.message, contains('timed out'));
      expect(age.cause, isA<TimeoutException>());
      expect(age.retryable, isTrue, reason: 'timeouts are transient');
      expect(onAuthFailedCalls, 0, reason: 'timeouts never call onAuthFailed');
      expect(refresher.calls, 1);

      // Timeouts are transient: the next 401 must start a new cycle.
      refresher.succeedWith = const AuthTokens(
        accessToken: 'B',
        refreshToken: 'rt2',
      );
      final res = await dio.get<Map<String, dynamic>>('/protected');
      expect(res.statusCode, 200);
      expect(refresher.calls, 2);
    }, timeout: const Timeout(Duration(seconds: 10)));

    test(
        'timeout during the session re-read: setTokens is never called '
        '(abandoned re-check)', () async {
      final inner = MemoryTokenProvider(accessToken: 'A', refreshToken: 'rt1');
      final gatedProvider = _SecondReadGatedProvider(inner);
      var onAuthFailedCalls = 0;
      var refresherCalls = 0;
      dio.interceptors.add(
        AuthRefreshInterceptor(
          dio: dio,
          tokenProvider: gatedProvider,
          refresher: (refreshToken, refreshDio) async {
            refresherCalls++;
            return const AuthTokens(accessToken: 'late', refreshToken: 'late');
          },
          config: const AuthRefreshConfig(refreshTimeout: Duration(seconds: 1)),
          onAuthFailed: (_) => onAuthFailedCalls++,
        ),
      );
      adapter.setHandler(
        (options) async => jsonResponse({'e': 1}, status: 401),
      );

      final future = dio.get<Map<String, dynamic>>('/protected');

      // The task blocks on the second getRefreshToken (the session
      // re-read, right before setTokens) while the timeout fires.
      final e = await outcome(future) as DioException;
      final age = e.error! as AuthRefreshException;
      expect(age.message, contains('timed out'));
      expect(
        gatedProvider.refreshReads,
        2,
        reason: 'the timeout fired while blocked on the re-read',
      );
      expect(onAuthFailedCalls, 0);
      expect(refresherCalls, 1);

      // Late unblock: the abandoned re-check must discard the result.
      gatedProvider.releaseRead();
      await pumpEventQueue(times: 30);
      expect(
        inner.setTokensCalls,
        0,
        reason: 'setTokens must never run after the timeout',
      );
      expect(inner.accessToken, 'A');
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('async onAuthFailed is awaited before waiters are rejected', () async {
      final refresher = GatedRefresher()
        ..failWith = const AuthRefreshException('refresh token revoked');
      var onAuthFailedStarted = false;
      var onAuthFailedFinished = false;
      dio.interceptors.add(
        AuthRefreshInterceptor(
          dio: dio,
          tokenProvider: provider,
          refresher: refresher.call,
          onAuthFailed: (cause) async {
            onAuthFailedStarted = true;
            await Future<void>.delayed(Duration.zero);
            onAuthFailedFinished = true;
          },
        ),
      );

      final future = dio.get<Map<String, dynamic>>('/protected');
      await refresher.started.future;
      refresher.release();

      final e = await outcome(future) as DioException;
      expect(e.error, isA<AuthRefreshException>());
      expect(onAuthFailedStarted, isTrue);
      expect(
        onAuthFailedFinished,
        isTrue,
        reason: 'the guard must await the async onAuthFailed '
            'before rejecting waiters',
      );
    });

    test('handler methods are called exactly once (success path)', () async {
      final refresher = GatedRefresher()
        ..succeedWith = const AuthTokens(accessToken: 'B', refreshToken: 'rt2');
      final guard = AuthRefreshInterceptor(
        dio: dio,
        tokenProvider: provider,
        refresher: refresher.call,
      );

      final options = _sentWith('A');
      final handler = _RecordingErrorHandler();
      guard.onError(_sent401(options), handler);
      await refresher.started.future;
      refresher.release();
      await pumpEventQueue(times: 50);

      expect(handler.resolveCalls, 1);
      expect(handler.rejectCalls, 0);
      expect(handler.nextCalls, 0);
    });

    test('handler methods are called exactly once (failure path)', () async {
      final refresher = GatedRefresher()
        ..failWith = const AuthRefreshException('refresh token revoked');
      final guard = AuthRefreshInterceptor(
        dio: dio,
        tokenProvider: provider,
        refresher: refresher.call,
      );

      final options = _sentWith('A');
      final handler = _RecordingErrorHandler();
      guard.onError(_sent401(options), handler);
      await refresher.started.future;
      refresher.release();
      await pumpEventQueue(times: 50);

      expect(handler.rejectCalls, 1);
      expect(handler.resolveCalls, 0);
      expect(handler.nextCalls, 0);
      expect(refresher.calls, 1);

      // A second 401 with the same sent token hits the memo: rejected
      // again, still no second refresh, still exactly one handler call.
      final handler2 = _RecordingErrorHandler();
      guard.onError(_sent401(_sentWith('A')), handler2);
      await pumpEventQueue(times: 50);
      expect(handler2.rejectCalls, 1);
      expect(handler2.resolveCalls, 0);
      expect(handler2.nextCalls, 0);
      expect(refresher.calls, 1, reason: 'memo must suppress the refresher');
    });

    group('terminal vs transient classification', () {
      Future<Object?> runSingleRequest(Dio guardDio, GatedRefresher refresher) {
        final future = guardDio.get<Map<String, dynamic>>('/protected');
        return refresher.started.future.then((_) {
          refresher.release();
          return outcome(future);
        });
      }

      test('DioException 401 from the refresher: terminal, memoized', () async {
        final refresher = GatedRefresher()
          ..failWith = _refreshEndpointError(401);
        var onAuthFailedCalls = 0;
        dio.interceptors.add(
          AuthRefreshInterceptor(
            dio: dio,
            tokenProvider: provider,
            refresher: refresher.call,
            onAuthFailed: (_) => onAuthFailedCalls++,
          ),
        );

        final e = await runSingleRequest(dio, refresher) as DioException;
        expect(e.error, isA<AuthRefreshException>());
        expect((e.error! as AuthRefreshException).retryable, isFalse);
        expect(onAuthFailedCalls, 1);
        expect(refresher.calls, 1);

        // Memoized: a later 401 with the same token must not refresh again.
        final later = await outcome(
          dio.get<Map<String, dynamic>>('/protected'),
        ) as DioException;
        expect(
            (later.error! as AuthRefreshException).cause, isA<DioException>());
        expect(refresher.calls, 1, reason: 'terminal failures are memoized');
        expect(
          onAuthFailedCalls,
          1,
          reason: 'memo rejections never re-fire onAuthFailed',
        );
      });

      test('DioException 400 from the refresher: terminal', () async {
        final refresher = GatedRefresher()
          ..failWith = _refreshEndpointError(400);
        var onAuthFailedCalls = 0;
        dio.interceptors.add(
          AuthRefreshInterceptor(
            dio: dio,
            tokenProvider: provider,
            refresher: refresher.call,
            onAuthFailed: (_) => onAuthFailedCalls++,
          ),
        );

        final e = await runSingleRequest(dio, refresher) as DioException;
        expect((e.error! as AuthRefreshException).retryable, isFalse);
        expect(onAuthFailedCalls, 1);
      });

      test('DioException 403 from the refresher: terminal', () async {
        final refresher = GatedRefresher()
          ..failWith = _refreshEndpointError(403);
        var onAuthFailedCalls = 0;
        dio.interceptors.add(
          AuthRefreshInterceptor(
            dio: dio,
            tokenProvider: provider,
            refresher: refresher.call,
            onAuthFailed: (_) => onAuthFailedCalls++,
          ),
        );

        final e = await runSingleRequest(dio, refresher) as DioException;
        expect((e.error! as AuthRefreshException).retryable, isFalse);
        expect(onAuthFailedCalls, 1);
      });

      test('DioException 503 from the refresher: transient, retried', () async {
        final refresher = GatedRefresher()
          ..failWith = _refreshEndpointError(503);
        var onAuthFailedCalls = 0;
        dio.interceptors.add(
          AuthRefreshInterceptor(
            dio: dio,
            tokenProvider: provider,
            refresher: refresher.call,
            onAuthFailed: (_) => onAuthFailedCalls++,
          ),
        );

        final e = await runSingleRequest(dio, refresher) as DioException;
        expect((e.error! as AuthRefreshException).retryable, isTrue);
        expect(onAuthFailedCalls, 0, reason: '5xx is transient');

        // The next 401 must attempt a fresh cycle.
        refresher
          ..failWith = null
          ..succeedWith = const AuthTokens(
            accessToken: 'B',
            refreshToken: 'rt2',
          );
        final res = await dio.get<Map<String, dynamic>>('/protected');
        expect(res.statusCode, 200);
        expect(refresher.calls, 2);
        expect(onAuthFailedCalls, 0);
      });

      test('custom isTerminalRefreshError override is respected', () async {
        final sentinel = StateError('treat me as terminal');
        final refresher = GatedRefresher()..failWith = sentinel;
        var onAuthFailedCalls = 0;
        dio.interceptors.add(
          AuthRefreshInterceptor(
            dio: dio,
            tokenProvider: provider,
            refresher: refresher.call,
            config: const AuthRefreshConfig(
              isTerminalRefreshError: _stateErrorIsTerminal,
            ),
            onAuthFailed: (_) => onAuthFailedCalls++,
          ),
        );

        final e = await runSingleRequest(dio, refresher) as DioException;
        // StateError is transient by default; the override makes it terminal.
        expect((e.error! as AuthRefreshException).retryable, isFalse);
        expect(onAuthFailedCalls, 1);

        // And it is memoized like any terminal failure.
        await outcome(dio.get<Map<String, dynamic>>('/protected'));
        expect(refresher.calls, 1, reason: 'override-driven terminal memo');
        expect(onAuthFailedCalls, 1);
      });
    });

    group('characterization — instant (zero-delay) refreshes', () {
      test(
          'terminal failure: the memo absorbs straggler waves '
          '(refresher and onAuthFailed once)', () async {
        var refresherCalls = 0;
        var onAuthFailedCalls = 0;
        dio.interceptors.add(
          AuthRefreshInterceptor(
            dio: dio,
            tokenProvider: provider,
            refresher: (refreshToken, refreshDio) async {
              refresherCalls++;
              throw const AuthRefreshException('refresh token revoked');
            },
            onAuthFailed: (_) => onAuthFailedCalls++,
          ),
        );

        // Each onError lands on its own event turn; the first cycle's
        // terminal failure is memoized before the others arrive, so the
        // remaining waiters reject from the memo instead of re-refreshing.
        final errors = await Future.wait(
          List.generate(
            3,
            (_) => outcome(dio.get<Map<String, dynamic>>('/protected')),
          ),
        );
        for (final e in errors) {
          expect(
            ((e as DioException).error! as AuthRefreshException).message,
            'refresh token revoked',
          );
        }
        expect(refresherCalls, 1);
        expect(onAuthFailedCalls, 1);
      });

      test(
          'transient failure: each waiter retries once (documented bounded '
          'churn, no hang)', () async {
        var refresherCalls = 0;
        var onAuthFailedCalls = 0;
        dio.interceptors.add(
          AuthRefreshInterceptor(
            dio: dio,
            tokenProvider: provider,
            refresher: (refreshToken, refreshDio) async {
              refresherCalls++;
              throw DioException(
                requestOptions: RequestOptions(path: ''),
                type: DioExceptionType.connectionError,
              );
            },
            onAuthFailed: (_) => onAuthFailedCalls++,
          ),
        );

        final errors = await Future.wait(
          List.generate(
            3,
            (_) => outcome(dio.get<Map<String, dynamic>>('/protected')),
          ),
        );
        expect(errors.whereType<DioException>(), hasLength(3));
        // Documented behavior: transient failures are never memoized, so a
        // zero-delay refresher lets each waiter lead one short cycle.
        expect(refresherCalls, 3);
        expect(
          onAuthFailedCalls,
          0,
          reason: 'transient failures never call onAuthFailed',
        );
      });
    });
  });
}

bool _stateErrorIsTerminal(Object error) => error is StateError;
