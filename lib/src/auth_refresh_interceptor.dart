// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import 'package:dio/dio.dart';

import 'await_with_cancel.dart';
import 'config.dart';
import 'constants.dart';
import 'exceptions.dart';
import 'refresh_coordinator.dart';
import 'token_provider.dart';

/// A Dio [Interceptor] that performs single-flight 401 token refresh.
///
/// * Only one refresh runs at a time, no matter how many requests fail
///   concurrently ([RefreshCoordinator]).
/// * All failed requests wait for the refresh and are replayed afterwards
///   with the new token.
/// * A request whose sent token differs from the current one (refresh
///   already completed after it was dispatched) is replayed immediately,
///   without triggering a second refresh.
/// * Every waiter failure is a [DioException] whose `error` is an
///   [AuthRefreshException] — no hangs, no unhandled async errors.
/// * **Terminal failures** (per [AuthRefreshConfig.isTerminalRefreshError]):
///   memoized for the sent access token and fire [OnAuthFailed] exactly
///   once; later 401s carrying the same token are rejected with the memoized
///   failure until the stored tokens change.
/// * **Transient failures** (timeouts, connection errors, 5xx refresh
///   responses): waiters are rejected with `AuthRefreshException(retryable:
///   true)`, [OnAuthFailed] is never called and nothing is memoized — the
///   next 401 starts a fresh cycle.
/// * **Session ended:** a 401 whose request was sent with a token while the
///   provider now has none (user logged out) is rejected immediately — no
///   refresh, no [OnAuthFailed].
/// * A request cancelled while waiting rejects immediately with a cancel
///   error; the refresh continues for the remaining waiters.
///
/// Do NOT use [QueuedInterceptor]-style locking: the guard is a plain
/// [Interceptor] and relies on the coordinator for serialization, which
/// avoids the classic `await dio.fetch()` inside a locked `onError`
/// deadlock.
class AuthRefreshInterceptor extends Interceptor {
  AuthRefreshInterceptor({
    required Dio dio,
    required TokenProvider tokenProvider,
    required TokenRefresher refresher,
    Dio? refreshDio,
    AuthRefreshConfig config = const AuthRefreshConfig(),
    OnAuthFailed? onAuthFailed,
  })  : _dio = dio,
        _tokenProvider = tokenProvider,
        _refresher = refresher,
        _refreshDio = refreshDio ?? _buildRefreshDio(dio),
        _config = config,
        _onAuthFailed = onAuthFailed,
        _coordinator = RefreshCoordinator();

  final Dio _dio;
  final TokenProvider _tokenProvider;
  final TokenRefresher _refresher;
  final Dio _refreshDio;
  final AuthRefreshConfig _config;
  final OnAuthFailed? _onAuthFailed;
  final RefreshCoordinator _coordinator;

  /// Sent access token of the last terminally failed refresh cycle, if any.
  String? _failedForToken;

  /// The memoized failure delivered to stragglers carrying
  /// [_failedForToken]. Cleared when a later cycle succeeds or when the
  /// request's sent token no longer matches the memo key.
  AuthRefreshException? _terminalFailure;

  /// Whether a refresh is currently in-flight.
  bool get isRefreshing => _coordinator.isRefreshing;

  /// Builds the [Dio] used for the refresh call.
  ///
  /// It copies the base options (timeouts, base URL, content type...), the
  /// [HttpClientAdapter] (preserving proxy / certificate pinning) and the
  /// transformer, but never the interceptors (preventing recursion).
  ///
  /// NOTE: the adapter instance is *shared* with the main [dio] — closing
  /// either [Dio] closes the other. Callers own the main `dio`'s lifetime
  /// and must not close them independently.
  static Dio _buildRefreshDio(Dio dio) {
    final clone = Dio(dio.options.copyWith());
    clone.httpClientAdapter = dio.httpClientAdapter;
    clone.transformer = dio.transformer;
    return clone;
  }

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    try {
      if (_config.shouldAttach(options)) {
        final token = await _tokenProvider.getAccessToken();
        if (token != null) {
          options.headers['Authorization'] = 'Bearer $token';
          // Store the token that is actually sent so the race guard in
          // onError can compare it against the provider's current token.
          options.extra[kTokenKey] = token;
        } else {
          // Remove possibly stale values (a replay copyWith may carry them).
          options.headers.remove('Authorization');
          options.extra.remove(kTokenKey);
        }
      }
      handler.next(options);
    } catch (e, st) {
      handler.reject(
        DioException(requestOptions: options, error: e, stackTrace: st),
      );
    }
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    var handled = false;
    void onceResolve(Response<dynamic> response) {
      if (!handled) {
        handled = true;
        handler.resolve(response);
      }
    }

    void onceReject(DioException error) {
      if (!handled) {
        handled = true;
        handler.reject(error);
      }
    }

    void onceNext(DioException error) {
      if (!handled) {
        handled = true;
        handler.next(error);
      }
    }

    try {
      final requestOptions = err.requestOptions;
      final cancelToken = requestOptions.cancelToken;

      // 1. Not refreshable (not a 401 per config) or already retried.
      if (!_config.shouldRefresh(err) ||
          requestOptions.extra[kRetryKey] == true) {
        return onceNext(err);
      }

      // 2. Request already cancelled — reject, never start a refresh.
      if (cancelToken?.isCancelled == true) {
        return onceReject(
          DioException(
            requestOptions: requestOptions,
            type: DioExceptionType.cancel,
            error: err,
          ),
        );
      }

      // 3. No token was sent with this request (e.g. login endpoint):
      //    a 401 here is a genuine authentication failure — pass through.
      final sent = requestOptions.extra[kTokenKey] as String?;
      if (sent == null) {
        return onceNext(err);
      }

      final current = await _tokenProvider.getAccessToken();

      // 4. Session ended: the request was sent with a token but the user
      //    is no longer authenticated (logout during flight). Reject
      //    without refreshing and without onAuthFailed — the app has
      //    already handled the logout.
      if (current == null) {
        return onceReject(
          DioException(
            requestOptions: requestOptions,
            response: err.response,
            type: DioExceptionType.badResponse,
            error: const AuthRefreshException(
              'session ended — no current access token',
            ),
          ),
        );
      }

      // 5. Race guard: the token was already refreshed after this request
      //    was dispatched — replay immediately, no second refresh.
      if (current != sent) {
        final response = await _replay(requestOptions);
        return onceResolve(response);
      }

      // 6. Terminal-failure memo: a previous cycle failed terminally for
      //    this exact sent token. Reject stragglers with the memoized
      //    failure — no refresher, no second onAuthFailed.
      final memo = _terminalFailure;
      if (memo != null && _failedForToken == sent) {
        return onceReject(
          DioException(
            requestOptions: requestOptions,
            response: err.response,
            type: DioExceptionType.badResponse,
            error: memo,
          ),
        );
      }

      // 7. Single-flight refresh, cancellable while waiting.
      AuthRefreshException? refreshError;
      try {
        await awaitWithCancel(
          _coordinator.execute(() => _refreshTask(requestOptions)),
          cancelToken,
          requestOptions,
        );
      } on AuthRefreshException catch (e) {
        refreshError = e;
      } on DioException catch (e) {
        // Cancellation (or any Dio-level failure) — reject directly.
        return onceReject(e);
      }

      if (refreshError != null) {
        return onceReject(
          DioException(
            requestOptions: requestOptions,
            response: err.response,
            type: DioExceptionType.badResponse,
            error: refreshError,
          ),
        );
      }

      // 8. Defensive check: cancelled between refresh and replay.
      if (cancelToken?.isCancelled == true) {
        return onceReject(
          DioException(
            requestOptions: requestOptions,
            type: DioExceptionType.cancel,
          ),
        );
      }

      // 9. Replay with the new token.
      final response = await _replay(requestOptions);
      return onceResolve(response);
    } on DioException catch (e) {
      return onceReject(e);
    } on AuthRefreshException catch (e) {
      return onceReject(
        DioException(requestOptions: err.requestOptions, error: e),
      );
    } catch (e, st) {
      return onceReject(
        DioException(
          requestOptions: err.requestOptions,
          error: e,
          stackTrace: st,
        ),
      );
    }
  }

  /// The refresh task executed under single-flight semantics.
  ///
  /// Throws only [AuthRefreshException] so each waiter can build its own
  /// [DioException] with its own [RequestOptions]. Terminally failing
  /// cycles are memoized for the leader's sent token and fire
  /// [OnAuthFailed] exactly once; transient cycles never do either.
  Future<void> _refreshTask(RequestOptions requestOptions) async {
    var abandoned = false;
    try {
      await (() async {
        // NOTES #7: capture the refresh token; fail fast when absent.
        final capturedRefresh = await _tokenProvider.getRefreshToken();
        if (capturedRefresh == null) {
          throw const AuthRefreshException('no refresh token — cannot refresh');
        }

        // Race guard (authoritative, inside the single-flight lock):
        // if the token was already refreshed after this request was
        // dispatched, skip the refresh entirely.
        final sent = requestOptions.extra[kTokenKey] as String?;
        final current = await _tokenProvider.getAccessToken();
        if (sent != null && current != null && sent != current) {
          return;
        }

        final tokens = await _refresher(capturedRefresh, _refreshDio);

        // NOTES #6: Future.timeout does not cancel running work — discard
        // the result if the timeout already fired.
        if (abandoned) return;

        // NOTES #7: the session must not have changed during the refresh
        // (logout or logout-then-login); fail all waiters otherwise.
        final currentRefresh = await _tokenProvider.getRefreshToken();
        if (currentRefresh == null || currentRefresh != capturedRefresh) {
          throw const AuthRefreshException('session changed during refresh');
        }

        // Re-check immediately before persisting: the timeout may have
        // fired during the await above.
        if (abandoned) return;

        await _tokenProvider.setTokens(tokens);

        // A successful cycle clears any memoized terminal failure.
        _failedForToken = null;
        _terminalFailure = null;
      })()
          .timeout(
        _config.refreshTimeout,
        onTimeout: () {
          abandoned = true;
          throw TimeoutException(
            'refresh timed out after ${_config.refreshTimeout}',
          );
        },
      );
    } catch (e, st) {
      // Terminal failures (per config.isTerminalRefreshError) are memoized
      // for the sent token and fire onAuthFailed once. Transient failures
      // — timeouts, network errors, 5xx — reject waiters with a retryable
      // AuthRefreshException and are never memoized.
      final isTerminal = _config.isTerminalRefreshError(e);
      final AuthRefreshException wrapped;
      if (e is AuthRefreshException) {
        wrapped = e;
      } else if (e is TimeoutException) {
        wrapped = AuthRefreshException(
          'refresh timed out after ${_config.refreshTimeout}',
          cause: e,
          retryable: !isTerminal,
        );
      } else {
        wrapped = AuthRefreshException(
          'refresh failed',
          cause: e,
          retryable: !isTerminal,
        );
      }
      if (isTerminal) {
        _failedForToken = requestOptions.extra[kTokenKey] as String?;
        _terminalFailure = wrapped;
        try {
          await _onAuthFailed?.call(wrapped);
        } catch (_) {
          // onAuthFailed failures must not break the rejection flow.
        }
      }
      Error.throwWithStackTrace(wrapped, st);
    }
  }

  /// Replays [original] with a fresh Authorization header.
  ///
  /// The original [RequestOptions] is never mutated: a copy is created with
  /// the retry flag set, [FormData] is cloned (it was finalized by the
  /// first send), and `dio.fetch` re-enters the request pipeline so
  /// [onRequest] attaches the current token.
  Future<Response<dynamic>> _replay(RequestOptions original) async {
    final extra = Map<String, dynamic>.from(original.extra);
    extra[kRetryKey] = true;

    var data = original.data;
    if (data is FormData) {
      try {
        data = data.clone();
      } catch (e, st) {
        Error.throwWithStackTrace(
          AuthRefreshException(
            'FormData replay failed: use MultipartFile.fromFile/fromBytes, '
            'or a fromStream factory that produces a fresh stream per call',
            cause: e,
          ),
          st,
        );
      }
    }

    final options = original.copyWith(extra: extra, data: data);
    return _replayFetch(options, data);
  }

  /// Sends the replayed request.
  ///
  /// For [FormData] replays the fetch runs inside a guarded zone: dio's
  /// `FormData.finalize()` reports non-replayable stream factories as an
  /// *unhandled* async error (it fire-and-forgets its internal write loop),
  /// which would otherwise crash the isolate. Capturing the zone lets the
  /// guard turn it into a clean [AuthRefreshException] rejection.
  ///
  /// CAVEAT: the guarded zone captures **all** uncaught async errors that
  /// fire while the replayed request is in flight — including errors
  /// escaping unrelated user interceptors or other request-pipeline code —
  /// and may misattribute them as FormData replay failures. If this guard
  /// rejects a FormData replay with an unexpected cause, check other
  /// interceptors first.
  Future<Response<dynamic>> _replayFetch(RequestOptions options, Object? data) {
    if (data is! FormData) {
      return _dio.fetch<dynamic>(options);
    }

    final zoneErrors = <Object>[];
    final completer = Completer<Response<dynamic>>();

    runZonedGuarded(
      () {
        try {
          _dio
              .fetch<dynamic>(options)
              .then(completer.complete, onError: completer.completeError);
        } catch (e, st) {
          completer.completeError(e, st);
        }
      },
      (Object e, StackTrace _) {
        zoneErrors.add(e);
      },
    );

    return completer.future.then((response) async {
      // Give the event loop a turn so late FormData stream errors surface
      // in the zone before we decide the replay succeeded.
      await Future<void>.delayed(Duration.zero);
      if (zoneErrors.isNotEmpty) {
        throw AuthRefreshException(
          'FormData replay failed: the underlying MultipartFile stream '
          'cannot produce a fresh stream (e.g. a fromStream factory '
          'reusing a single-subscription stream)',
          cause: zoneErrors.first,
        );
      }
      return response;
    });
  }
}
