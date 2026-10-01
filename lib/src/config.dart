import 'dart:async';

import 'package:dio/dio.dart';

import 'exceptions.dart';
import 'token_provider.dart';

/// Callback invoked exactly once per **terminally** failed refresh cycle.
///
/// Transient failures (timeouts, connection errors, 5xx responses from the
/// refresh endpoint) reject the waiting requests with a retryable
/// [AuthRefreshException] but never invoke this callback.
///
/// It receives the [AuthRefreshException] that all waiters will also receive.
/// Both sync and async callbacks are supported; exceptions thrown by the
/// callback itself are swallowed by the guard.
typedef OnAuthFailed = FutureOr<void> Function(AuthRefreshException cause);

/// User-supplied refresh logic.
///
/// Receives the refresh token captured at the start of the refresh task
/// (never null — the guard fails early when no refresh token exists) and a
/// [Dio] instance dedicated to the refresh call (no auth guard attached).
/// Return the new tokens on success; throw to fail the refresh.
typedef TokenRefresher = Future<AuthTokens> Function(
  String refreshToken,
  Dio refreshDio,
);

/// Configuration for [AuthRefreshInterceptor].
class AuthRefreshConfig {
  const AuthRefreshConfig({
    this.shouldRefresh = _defaultShouldRefresh,
    this.shouldAttach = _defaultShouldAttach,
    this.refreshTimeout = const Duration(seconds: 10),
    this.isTerminalRefreshError = _defaultIsTerminalRefreshError,
  });

  /// Decides whether an error should trigger a refresh.
  /// Defaults to HTTP 401 only.
  final bool Function(DioException err) shouldRefresh;

  /// Decides whether the guard should attach an Authorization header to a
  /// request. Defaults to all requests.
  final bool Function(RequestOptions req) shouldAttach;

  /// Timeout for the entire refresh task (reading the refresh token,
  /// calling the refresher, and persisting the new tokens).
  /// Defaults to 10 seconds.
  ///
  /// Note: [Future.timeout] does not cancel the running work — a refresher
  /// that completes after the timeout has its result discarded and never
  /// persisted.
  final Duration refreshTimeout;

  /// Classifies a refresh-cycle error as **terminal** (memoized for the
  /// sent token, fires [OnAuthFailed] once) or **transient** (rejects
  /// waiters with a retryable [AuthRefreshException], never memoized, the
  /// next 401 starts a fresh cycle).
  ///
  /// The default classification:
  ///
  /// * [AuthRefreshException] — terminal when `retryable == false`
  ///   (this also covers the guard's own `'no refresh token'` and
  ///   `'session changed'` failures);
  /// * [DioException] with response status **400, 401 or 403** — terminal
  ///   (the backend rejected the refresh token);
  /// * [DioException] of type `connectionTimeout`, `sendTimeout`,
  ///   `receiveTimeout` or `connectionError` — transient;
  /// * [DioException] with any **5xx** response — transient;
  /// * [TimeoutException] — transient;
  /// * anything else — transient.
  final bool Function(Object error) isTerminalRefreshError;

  static bool _defaultShouldRefresh(DioException err) =>
      err.response?.statusCode == 401;

  static bool _defaultShouldAttach(RequestOptions req) => true;

  static bool _defaultIsTerminalRefreshError(Object error) {
    if (error is AuthRefreshException) return !error.retryable;
    if (error is TimeoutException) return false;
    if (error is DioException) {
      final status = error.response?.statusCode;
      return status == 400 || status == 401 || status == 403;
    }
    return false;
  }
}
