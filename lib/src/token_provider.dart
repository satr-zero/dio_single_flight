/// Immutable token pair produced by a successful refresh.
class AuthTokens {
  const AuthTokens({required this.accessToken, this.refreshToken});

  /// The new access token. Never null — a refresh that cannot produce an
  /// access token must throw instead.
  final String accessToken;

  /// The new refresh token. May be null when the backend does not rotate
  /// refresh tokens; in that case the previously stored one is kept.
  final String? refreshToken;
}

/// Storage abstraction for auth tokens.
///
/// Implementations may back this with `flutter_secure_storage`, `hive`,
/// shared preferences, or plain memory. The package never imports a
/// storage implementation itself — the app owns persistence.
abstract class TokenProvider {
  /// The access token to attach to outgoing requests, or null when the
  /// user is not authenticated.
  Future<String?> getAccessToken();

  /// The refresh token used by the refresher, or null when the user is not
  /// authenticated / logged out.
  Future<String?> getRefreshToken();

  /// Persists [tokens] after a successful refresh.
  Future<void> setTokens(AuthTokens tokens);

  /// Removes all tokens (logout).
  Future<void> clear();
}

/// Simple in-memory [TokenProvider] intended for tests and examples.
class MemoryTokenProvider implements TokenProvider {
  MemoryTokenProvider({this.accessToken, this.refreshToken});

  /// The stored access token.
  String? accessToken;

  /// The stored refresh token.
  String? refreshToken;

  /// Number of times [setTokens] was called. Useful for asserting that a
  /// refresh did or did not persist tokens.
  int setTokensCalls = 0;

  /// Number of times [clear] was called.
  int clearCalls = 0;

  @override
  Future<String?> getAccessToken() async => accessToken;

  @override
  Future<String?> getRefreshToken() async => refreshToken;

  @override
  Future<void> setTokens(AuthTokens tokens) async {
    setTokensCalls++;
    accessToken = tokens.accessToken;
    // Keep the previous refresh token when the new one is null
    // (backends that do not rotate refresh tokens).
    refreshToken = tokens.refreshToken ?? refreshToken;
  }

  @override
  Future<void> clear() async {
    clearCalls++;
    accessToken = null;
    refreshToken = null;
  }
}
