# dio_single_flight 🛡️

**Automatic token refresh for [Dio](https://pub.dev/packages/dio) — done exactly once, no matter how many requests fail at the same time.**

<!-- Enable these badges after publishing and after CI exists:
[![pub package](https://img.shields.io/pub/v/dio_single_flight.svg)](https://pub.dev/packages/dio_single_flight)
[![CI](https://github.com/satr-zero/dio_single_flight/actions/workflows/ci.yml/badge.svg)](https://github.com/satr-zero/dio_single_flight/actions)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
-->

Pure Dart. Only one dependency: `dio`. Works in Flutter, Dart CLI, and servers.

---

## The problem (in 30 seconds)

Most apps log users in with two tokens:

- **Access token** — a short-lived key sent with every request. It expires quickly (often in minutes).
- **Refresh token** — a longer-lived key used to get a *new* access token.

Now imagine your home screen sends **5 requests at the same moment**: profile, orders, notifications, cart, and settings. The access token has just expired. The server answers all five with **401 Unauthorized**.

What happens next in a naive setup?

```
Request 1 fails → "I'll refresh the token!"
Request 2 fails → "I'll refresh the token!"
Request 3 fails → "I'll refresh the token!"
Request 4 fails → "I'll refresh the token!"
Request 5 fails → "I'll refresh the token!"

Result: 5 refresh calls at once.
Many servers allow a refresh token to be used only ONCE,
so 1 succeeds and 4 fail → the user gets logged out for no reason. 😡
```

Other common problems:

- Some requests **hang forever** waiting for a refresh that never finishes.
- When the refresh fails, requests fail in a **messy, unclear** way.
- Dio's `QueuedInterceptor` can **deadlock** if it is used carelessly for this job.

## The solution

`dio_single_flight` puts **one guard** at the door:

```
Request 1 fails → starts the refresh
Request 2 fails → waits for the same refresh
Request 3 fails → waits for the same refresh
Request 4 fails → waits for the same refresh
Request 5 fails → waits for the same refresh

Refresh succeeds → all 5 requests are replayed with the new token ✅
Refresh fails    → all 5 requests fail immediately with a clear error ✅
```

Think of five people at a locked door. Instead of everyone running off to find a key, **one person goes**, and everyone comes in when they return.

## What you get

| Feature | What it means for you |
|---|---|
| **Single-flight refresh** | 20 failed requests at once → exactly **1** refresh call. |
| **Automatic replay** | Failed requests are retried for you after a successful refresh. Your code never notices. |
| **Clean failure** | If the refresh fails, every waiting request fails right away with a clear `AuthRefreshException`. Nothing hangs. |
| **Terminal vs. temporary failures** | A dead session triggers your logout callback. A network hiccup does **not** log your user out. |
| **No logout storms** | Late 401s after a failed refresh or a logout are rejected immediately — no repeated refresh attempts, no repeated logout callbacks. |
| **Cancellation support** | If the user leaves the screen and you cancel a request while it waits, it stops immediately. Other requests keep going. |
| **Stale-token protection** | A late 401 caused by an *old* token is replayed with the fresh token — it does not trigger a second refresh. |
| **Safe file uploads** | `FormData` is cloned before the retry, so uploads can be replayed. |
| **Bring your own storage** | Secure storage, Hive, SharedPreferences, memory — you choose. |
| **Tiny and focused** | Pure Dart, one dependency (`dio`). |

## Installation

```yaml
dependencies:
  dio: ^5.5.0
  dio_single_flight: ^0.1.0
```

```bash
dart pub get
```

Requires Dart `^3.3.0` and `dio ^5.5.0`. (Older Dio versions can hang when replaying a `FormData` that cannot be re-sent, so they are not supported.)

## Quick start

```dart
import 'package:dio/dio.dart';
import 'package:dio_single_flight/dio_single_flight.dart';

void main() async {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));

  // Where your tokens live. MemoryTokenProvider is great for trying things out.
  final tokens = MemoryTokenProvider(
    accessToken: 'my-access-token',
    refreshToken: 'my-refresh-token',
  );

  dio.interceptors.add(
    AuthRefreshInterceptor(
      dio: dio,
      tokenProvider: tokens,

      // HOW to get a new token. You write this part (it depends on your API).
      refresher: (refreshToken, refreshDio) async {
        final response = await refreshDio.post(
          '/auth/refresh',
          data: {'refreshToken': refreshToken},
        );
        return AuthTokens(
          accessToken: response.data['accessToken'] as String,
          refreshToken: response.data['refreshToken'] as String?,
        );
      },

      // WHAT to do when the session is really over (see "Failures" below).
      onAuthFailed: (cause) async {
        await tokens.clear();
        // Navigate to the login screen here.
      },
    ),
  );

  // Use Dio exactly as you always do. The interceptor handles the rest.
  final response = await dio.get('/orders');
  print(response.data);
}
```

That's it. You don't add `Authorization` headers yourself, and you don't write retry code. A runnable offline version is in [`example/main.dart`](example/main.dart).

> **Important:** the `refresher` receives a special `refreshDio`. It has **no interceptor attached**, so a failing refresh call can never trigger another refresh (no infinite loops).

## Where do I store tokens? (`TokenProvider`)

The package doesn't care how you save tokens. Implement four small methods:

```dart
abstract class TokenProvider {
  Future<String?> getAccessToken();
  Future<String?> getRefreshToken();
  Future<void> setTokens(AuthTokens tokens);
  Future<void> clear();
}
```

Example with [`flutter_secure_storage`](https://pub.dev/packages/flutter_secure_storage):

```dart
class SecureTokenProvider implements TokenProvider {
  final _storage = const FlutterSecureStorage();

  @override
  Future<String?> getAccessToken() => _storage.read(key: 'access');

  @override
  Future<String?> getRefreshToken() => _storage.read(key: 'refresh');

  @override
  Future<void> setTokens(AuthTokens tokens) async {
    await _storage.write(key: 'access', value: tokens.accessToken);
    if (tokens.refreshToken != null) {
      await _storage.write(key: 'refresh', value: tokens.refreshToken);
    }
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: 'access');
    await _storage.delete(key: 'refresh');
  }
}
```

## Failures: when is the user logged out?

Not every refresh failure means the session is over. The package separates two kinds:

| Kind | Examples | What happens |
|---|---|---|
| **Terminal** (session is really over) | Refresh endpoint answers **400, 401 or 403**; no refresh token stored; session changed during the refresh | `onAuthFailed` is called **once**. Waiting requests fail with `AuthRefreshException` (`retryable: false`). |
| **Transient** (try again later) | Timeout, no connection, **5xx** from the refresh endpoint | `onAuthFailed` is **not** called. Waiting requests fail with `AuthRefreshException` (`retryable: true)`. The next 401 will try a fresh refresh. |

So a bad Wi-Fi moment will not throw your user back to the login screen.

In your `refresher`, just let errors propagate. If your server answers the refresh call with `401`, the thrown `DioException` is treated as terminal automatically.

Handling it where you call your API:

```dart
try {
  await dio.get('/profile');
} on DioException catch (e) {
  final error = e.error;
  if (error is AuthRefreshException) {
    if (error.retryable) {
      // Temporary problem (network, server down). Offer "Try again".
    } else {
      // Session is over. onAuthFailed already ran; show the login screen.
    }
  } else {
    // Some other network error.
  }
}
```

**No logout storms.** After a terminal failure, late 401s that carry the same expired token are rejected immediately — without calling your refresher or `onAuthFailed` again. And if the user already logged out, requests that were still in flight are rejected right away with a "session ended" error, with no refresh attempt.

## Configuration

```dart
AuthRefreshInterceptor(
  // ...
  config: AuthRefreshConfig(
    // Which errors should trigger a refresh. Default: HTTP 401 only.
    shouldRefresh: (err) => err.response?.statusCode == 401,

    // Which requests get the token attached. Default: all of them.
    // Skip your login and refresh endpoints:
    shouldAttach: (req) => !req.path.startsWith('/auth/'),

    // How long a refresh may take before it counts as failed. Default: 10 seconds.
    refreshTimeout: const Duration(seconds: 10),

    // Decide which refresh errors are terminal (session over).
    // The default is described in the table above; override it if your API differs.
    isTerminalRefreshError: (error) =>
        error is DioException && error.response?.statusCode == 401,
  ),
);
```

Requests that were sent **without** a token (for example a wrong-password `401` on `/auth/login`) never trigger a refresh.

## Cancelling requests

Use Dio's `CancelToken` as usual:

```dart
final cancelToken = CancelToken();

dio.get('/feed', cancelToken: cancelToken);

// The user leaves the screen:
cancelToken.cancel();
```

If the request is waiting for a refresh when you cancel it, it stops immediately with `DioExceptionType.cancel`. The refresh keeps running for the other requests.

## File uploads (`FormData`)

A `FormData` can only be sent once, so the interceptor **clones** it before replaying. This works out of the box with:

```dart
MultipartFile.fromFile(path)
MultipartFile.fromBytes(bytes)
MultipartFile.fromString(text)
MultipartFile.fromStream(() => File(path).openRead(), length) // factory creates a NEW stream each time
```

⚠️ Avoid `MultipartFile.fromStream` with a factory that returns the *same* single-use stream every time. That upload can't be replayed, and the request will fail with an `AuthRefreshException`.

## Good to know

- **POST/PATCH replay.** If the server processed a request but still answered 401, replaying it could run it twice. Use idempotent endpoints, or exclude sensitive endpoints with `shouldRefresh`.
- **Only one retry.** A replayed request that gets 401 *again* is not retried a second time. This prevents infinite loops.
- **One interceptor per Dio.** Each `Dio` instance needs its own `AuthRefreshInterceptor`.
- **Shared adapter.** By default the internal `refreshDio` copies your Dio's options and reuses its HTTP adapter (so proxies and certificate pinning keep working). Because of that, don't close `refreshDio` separately — close your main `dio`. You can also pass your own `refreshDio:` if you need full control.
- **Upload replay and error attribution.** While a `FormData` request is replayed, the package watches for uncaught async errors in that call. In rare cases an unrelated error from another interceptor of yours that fires at the same moment could be reported as a replay failure. The original error is kept in `AuthRefreshException.cause`.

## FAQ

**Do I need this if I only send one request at a time?**
Probably not. It shines when several requests can fail together — home screens, dashboards, background sync, uploads.

**Why not just use `QueuedInterceptor`?**
It processes requests one by one, and awaiting a replay on the same `Dio` from inside it can deadlock. This package uses a normal `Interceptor` plus a small coordinator, so nothing blocks the queue.

**Does it work without Flutter?**
Yes. It's pure Dart.

**Does it store my tokens?**
No. You provide a `TokenProvider`; the interceptor only calls its methods.

**What if my refresh endpoint is on a different server?**
Do the call with `refreshDio` using a full URL, or inject your own `refreshDio:`.

## How it works (for the curious)

1. `onRequest`: attaches `Authorization: Bearer <token>` and remembers which token was sent.
2. `onError` on a 401: asks the `RefreshCoordinator` to refresh. The first caller starts the work; everyone else awaits the **same Future**.
3. Inside the refresh, the interceptor checks whether the token has *already* been renewed by someone else. If yes, it skips refreshing.
4. On success, tokens are saved through your `TokenProvider` and every waiting request is replayed. On failure, they all fail together with an `AuthRefreshException`.

## Contributing

Issues and pull requests are welcome. Before opening a PR:

```bash
dart analyze
dart test
```

## License

MIT — see [LICENSE](LICENSE).