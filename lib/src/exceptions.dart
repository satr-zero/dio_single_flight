/// Thrown when a token refresh fails, times out, or cannot proceed
/// (e.g. the session changed during the refresh).
///
/// Always delivered to request waiters wrapped in a `DioException` via its
/// `error` field, so consumer code keeps handling `DioException` while being
/// able to distinguish refresh failures via `err.error is AuthRefreshException`.
///
/// Retry classification:
///
/// * [retryable] `false` (default) — **terminal** for the sent access token:
///   the guard memoizes the failure and rejects later 401s carrying the same
///   token without calling the refresher or [OnAuthFailed] again, until the
///   stored tokens change. Refreshers should throw a non-retryable
///   `AuthRefreshException` for fatal conditions (refresh token revoked or
///   rejected by the backend).
/// * [retryable] `true`, and any non-`AuthRefreshException` thrown by the
///   refresher (including network errors), and refresh timeouts —
///   **transient**: never memoized; the next 401 starts a fresh refresh
///   cycle.
class AuthRefreshException implements Exception {
  const AuthRefreshException(this.message,
      {this.cause, this.retryable = false});

  final String message;

  /// The underlying error, if any (e.g. [TimeoutException], the error thrown
  /// by the user-supplied refresher).
  final Object? cause;

  /// Whether a later 401 may retry the refresh. See the class docs for the
  /// full classification.
  final bool retryable;

  @override
  String toString() {
    if (cause != null) {
      return 'AuthRefreshException: $message (cause: $cause)';
    }
    return 'AuthRefreshException: $message';
  }
}
