# NOTES — Known AuthRefreshInterceptor Design Issues to Fix in Phase 2

> Recorded during Phase 1 spike. No AuthRefreshInterceptor code exists yet.
> These 8 points must be addressed when implementing `lib/src/auth_refresh_interceptor.dart` and related files.

## Spike Results

### Initial spike — 2026-09-30 (dio ^5.11.1, Dart 3.13.2)

Verified in a throwaway Dart project with `dio ^5.11.1` on Dart 3.13.2.

| Item | Result |
|------|--------|
| `RequestOptions.copyWith` | **Exists**. Signature `copyWith({extra, data, path, method, headers, queryParameters, ...})`. Tested: `ro.copyWith(extra: {...})` preserves `path`/`method`; `copyWith(data: ...)` works. Replay should use `original.copyWith(extra: newExtra, data: clonedData)`. |
| `FormData.clone()` | **Exists**. `fd.clone()` copies `fields` and `files`, preserves `boundaryName`, `camelCaseContentDisposition`, and `_boundary`. `fd.finalize()` is single-use — second `finalize()` without `clone()` throws `StateError`. See follow-up spike below for file-type-specific clone behaviour. |
| `CancelToken.whenCancel` | **Exists**. Type is `Future<DioException>` (`Future` that completes with a `DioException` when `cancel()` is called, stays pending otherwise). `cancel("reason")` resolves it with a `DioException` carrying that reason. **Not** `Future<void>` — Phase 2 code must handle `DioException` value, not `_`. |
| `BaseOptions.copyWith` | **Exists**. `BaseOptions(baseUrl: ...).copyWith(baseUrl: ...)` preserves `connectTimeout` etc. Needed for `refreshDio` construction. |
| `Dio.httpClientAdapter` | Type `IOHttpClientAdapter` on VM. Assigning `refreshDio.httpClientAdapter = dio.httpClientAdapter` shares the same instance — closing one closes the other. |
| Pub versions pinned | `dio: ^5.11.1` (latest), `lints: ^6.1.0` (latest), `test: ^1.32.0` (latest), `http_mock_adapter: ^0.6.1` (latest, depends on `dio ^5.3.2`, compatible). `mocktail` removed — unused in Phase 1, will be re-added only if Phase 2 needs it. Verified via `pub.dev` on 2026-09-30. |

### Follow-up spike — 2026-09-30 (FormData send + clone)

Sent a `FormData` through a real `finalize()` → `drain()` cycle, then cloned the already-finalized `FormData` and sent the clone.

| Case | Result |
|------|--------|
| `MultipartFile.fromFile` (real temp file) | **Succeeds**. `fd1.finalize()` → `drain()` succeeds. `fd1.clone()` on the already-finalized `fd1` produces a fresh `FormData` with `isFinalized == false`, same `boundary`, cloned `MultipartFile` with `isFinalized == false`. `fd2.finalize()` → `drain()` succeeds (250 bytes). Cloning the clone (`fd2.clone()` after `fd2` finalized) also succeeds. No throw at clone time or send time. |
| `MultipartFile.fromStream` with replayable factory (`() => Stream.fromIterable([bytes])`) | **Succeeds**. Factory creates a **new** `Stream` on every call. `fd1.finalize()` → `drain()` and `fd1.clone().finalize()` → `drain()` both succeed. Clone only succeeds because the factory can produce a fresh stream. |
| `MultipartFile.fromStream` with single-subscription factory (`() => sameController.stream`) | **Fails**. `FormData.clone()` itself does not throw (it just copies the factory reference via `MultipartFile.clone()`), but `clonedFormData.finalize()` → `drain()` throws `Bad state: Stream has already been listened to.` as an **unhandled async error** (crashes the isolate if uncaught). Root cause: the factory returns the same single-subscription `Stream` instance that was already listened to. Correct wording: **`fromStream` clone only fails when the factory cannot produce a fresh stream** — a factory that returns a new stream each time (e.g. `() => File.openRead()`, `() => Stream.value(bytes)`) is safe; a factory that reuses a single `StreamController.stream` is not. |

**Implication for Phase 2:** `dio_single_flight` must `try/catch` around `_replay`'s `FormData.clone()` **and** around `dio.fetch(cloned)` / `finalize()` — the `Stream has already been listened to` error surfaces at send time, not clone time. Wrap it as `AuthRefreshException` inside a `DioException` and document: use `MultipartFile.fromFile`/`fromBytes`/`fromStream` with a factory that creates a **new** stream per call; reusing a single-subscription stream will fail on replay.

---

## 1. `_awaitWithCancel` — Completer, not `whenCancel.then(throw)`

**Problem:** `whenCancel.then((_) => throw DioException(...))` creates a `Future` that will reject *unobserved* if the coordinator succeeds first and `cancel()` is called later (e.g. after retry succeeds). That orphan rejection triggers `Unhandled exception`.

**Fix for Phase 2 — uses `Completer` and correctly handles `whenCancel: Future<DioException>`:**

```dart
Future<void> awaitWithCancel(
  Future<void> coordinatorFuture,
  CancelToken? token,
  RequestOptions opts,
) {
  if (token == null) return coordinatorFuture;
  final completer = Completer<void>();

  // whenCancel is Future<DioException>, not Future<void>.
  // Completer wins once — whichever completes first settles the result;
  // the loser is ignored via isCompleted guard, so no unhandled error.
  token.whenCancel.then((DioException cancelError) {
    if (!completer.isCompleted) {
      completer.completeError(
        DioException(
          requestOptions: opts,
          type: DioExceptionType.cancel,
          error: cancelError,
        ),
      );
    }
  });

  coordinatorFuture.then(
    (_) {
      if (!completer.isCompleted) completer.complete();
    },
    onError: (Object e, StackTrace s) {
      if (!completer.isCompleted) completer.completeError(e, s);
    },
  );

  return completer.future;
}
```

No `Future.any`, no `whenCancel.then(throw)`. The losing side is never left as an unobserved error because the `Completer` absorbs exactly one outcome and the other branch is gated by `isCompleted`.

**Required test:** success followed by late cancel produces no uncaught error.

```dart
test('late cancel after success produces no uncaught error', () async {
  final uncaught = <Object>[];
  await runZonedGuarded(() async {
    final token = CancelToken();
    final coordinatorFuture = Future<void>.delayed(
      const Duration(milliseconds: 10),
    );
    final guarded = awaitWithCancel(coordinatorFuture, token, RequestOptions(path: '/test'));
    await guarded; // succeeds
    token.cancel('late'); // cancel AFTER success
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }, (e, s) => uncaught.add(e));
  await Future<void>.delayed(Duration.zero);
  expect(uncaught, isEmpty);
});
```

## 2. `onError`: do not `rethrow` inside `DioException` catch

```dart
// Bad:
} on DioException catch (e) {
  if (e.type == DioExceptionType.cancel) return onceReject(e);
  rethrow; // loses original error identity, double-wraps
}
// Good:
} on DioException catch (e) {
  return onceReject(e);
}
```

Single `return onceReject(e);` — no branch, no `rethrow`. `_awaitWithCancel` only throws `DioExceptionType.cancel`; any other `DioException` path is also a direct reject.

## 3. If `extra[kTokenKey]` is absent → do not refresh

If `extra` has no `kTokenKey`, no token was sent (e.g. login endpoint that is unauthenticated). A 401 from that endpoint must NOT trigger a refresh — just `handler.next(err)`.

```dart
final sent = err.requestOptions.extra[kTokenKey] as String?;
if (sent == null) return onceNext(err);
```

This avoids refreshing on login 401s and avoids infinite loops.

## 4. Merge `TimeoutException` and generic `catch` so `onAuthFailed` is called exactly once

Do not have two separate `on TimeoutException` / `on Exception` branches each calling `onAuthFailed`. One catch that wraps to `AuthRefreshException` and calls `onAuthFailed` once:

```dart
try {
  await taskWithTimeout;
} catch (e, st) {
  final wrapped = e is AuthRefreshException
      ? e
      : e is TimeoutException
          ? AuthRefreshException('refresh timed out after ${config.refreshTimeout}', e)
          : AuthRefreshException('refresh failed', e);
  try { await onAuthFailed?.call(wrapped); } catch (_) {}
  Error.throwWithStackTrace(wrapped, st);
}
```

## 5. `onAuthFailed` signature

```dart
typedef OnAuthFailed = FutureOr<void> Function(AuthRefreshException cause);
```

Called with `AuthRefreshException` (not `DioException`). Awaited, `try/catch` swallowed. Called exactly once per failed cycle — inside the leader's task, before rethrow.

## 6. Timeout applies to whole task + abandoned flag

`Future.timeout` does **not** cancel the running work. If the refresher finishes *after* the timeout, it must NOT call `setTokens` and must not overwrite newer tokens.

Wrap the entire refresh work (including `getRefreshToken` + `refresher` + `setTokens`) in `.timeout(...)` and guard `setTokens` with a per-task `abandoned` flag (or generation counter). The flag is set when the timeout fires; the late completion checks it before persisting.

```dart
bool abandoned = false;
try {
  await (() async {
    final rt = await tokenProvider.getRefreshToken();
    if (rt == null) throw AuthRefreshException('no refresh token');
    final tokens = await refresher(rt, refreshDio);
    if (abandoned) return; // timeout already won — discard result
    // also see #7 session check here
    await tokenProvider.setTokens(tokens);
  })().timeout(
    config.refreshTimeout,
    onTimeout: () {
      abandoned = true;
      throw TimeoutException('refresh timed out after ${config.refreshTimeout}');
    },
  );
} catch (e, st) {
  // #4 path wraps TimeoutException → AuthRefreshException and calls onAuthFailed once
}
```

Default `AuthRefreshConfig.refreshTimeout = Duration(seconds: 10)`.

**Required test:** refresher completes after timeout → `setTokens` is never called.

```dart
test('refresher completing after timeout does not call setTokens', () async {
  final provider = FakeTokenProvider(refreshToken: 'rt');
  // refresher takes longer than timeout
  // assert provider.setTokensCallCount == 0 after the timeout error propagates
});
```

## 7. Gate `setTokens` — capture refresh token + session-change check

Capture the refresh token at the start of the task. If it is `null` (e.g. unauthenticated / already logged out), fail immediately without calling `refresher`:

```dart
final capturedRefresh = await tokenProvider.getRefreshToken();
if (capturedRefresh == null) {
  throw AuthRefreshException('no refresh token — cannot refresh');
}
final tokens = await refresher(capturedRefresh, refreshDio);
```

Before `setTokens`, re-read the refresh token. If it is `null` **or differs** from `capturedRefresh`, the session changed during refresh (logout, or logout-then-login with new tokens). Do **not** return silently — throw `AuthRefreshException('session changed during refresh')` so all waiters fail cleanly instead of hanging or seeing stale success:

```dart
final currentRefresh = await tokenProvider.getRefreshToken();
if (currentRefresh == null || currentRefresh != capturedRefresh) {
  throw AuthRefreshException('session changed during refresh');
}
if (abandoned) return; // #6 guard still applies
await tokenProvider.setTokens(tokens);
```

This prevents overwriting newly issued tokens from a fresh login.

**Required tests:**

- `logout during refresh`: clear refresh token mid-refresh → all waiters get `AuthRefreshException('session changed')`, `setTokens` never called, new login tokens not overwritten.
- `logout-then-login during refresh`: captured `rt1`, then `setTokens(AuthTokens(access: 'new', refresh: 'rt2'))`, then original refresher returns `AuthTokens(access: 'stale')` → assert `setTokens` not called with stale, stored tokens remain `rt2`.
- `null refresh at start`: `getRefreshToken() == null` before `refresher` → refresher never invoked, waiters fail with `AuthRefreshException`.

## 8. Explicit FormData clone-failure tests

When `FormData.clone()` / `finalize()` throws (e.g. single-subscription stream already listened to, or `FormData` already finalized without clone), wrap as `AuthRefreshException` inside a `DioException` for the waiter — and add tests:

- `FormData` with `MultipartFile.fromFile` (or `fromBytes`) → clone succeeds, replay succeeds.
- `FormData` with `MultipartFile.fromStream` and **replayable** factory (`() => Stream.value(bytes)`) → clone succeeds, replay succeeds.
- `FormData` with `MultipartFile.fromStream` and **single-subscription** factory reusing the same `StreamController.stream` → `clone()` succeeds but `finalize()` throws `Bad state: Stream has already been listened to.` → caught → `DioException(error is AuthRefreshException)` rejected, not unhandled/crash. Document: `fromStream` clone only fails when the factory cannot produce a fresh stream.

Use a custom `HttpClientAdapter` stub or `http_mock_adapter` to force a 401 then replay with `FormData`. Assert no hang and correct error wrapping.

---

## Batch B findings (2026-09-30, Phase 2)

Verified while writing the integration suites; recorded for the README and future maintainers.

### Instant-refresh herding (edge case, by design)

Dio invokes each request's `onError` on a **separate event-loop turn** (each
interceptor wrapper wraps the callback in `Future(...)`). A refresh cycle
that completes **entirely within microtasks** — only possible when the
refresher has zero I/O, e.g. an in-memory test double — finishes before the
next waiter's `onError` runs, so each waiter becomes its own leader.

- **Success path:** harmless — the race guard sees `sent != current` and
  skips the redundant refresh (this is why even a zero-delay refresher
  yields `refresherCalls == 1` for concurrent successes).
- **Failure path:** waiters retry the refresh sequentially (bounded by the
  number of waiters, each still rejected cleanly, no hang, no unhandled
  error).

A real refresh call always spans at least one event turn (network I/O), so
concurrent waiters join the in-flight cycle in production. The tests use
20–30 ms delays to model realistic timing. Do NOT "fix" this by keeping a
completed `_future` alive — that is the stale-Future bug from Phase 1.

### `CancelToken.requestOptions` is never set by dio's core

`CancelToken.cancel()` builds its `DioException` with
`requestOptions ?? RequestOptions()` — an **empty** options object, because
`DioMixin` never assigns `cancelToken.requestOptions`. Consequence: cancel
errors delivered by dio carry no `extra`/headers; assertions like
`e.requestOptions.extra[kRetryKey]` are meaningless on adapter-level cancel
errors. The guard's own `awaitWithCancel` builds its cancel `DioException`
with the waiter's real `RequestOptions`, so the mid-refresh-cancel path is
unaffected.

### `StreamController.close()` hangs without a listener

`await controller.close()` on a controller nobody has listened to never
completes (the done future waits for event delivery). Caused a 30 s test
timeout; fixed by cascading `..close()` without awaiting. Test-only gotcha.

### FormData replay via guarded zone

`FormData.finalize()` fire-and-forgets its internal write loop, so a
non-replayable `fromStream` factory surfaces as an **unhandled zone error**
from *inside dio*, not as a fetch failure. `AuthRefreshInterceptor._replayFetch`
runs FormData replays inside `runZonedGuarded`, pumps one event turn after
the fetch settles, and converts any captured zone error into an
`AuthRefreshException` rejection. The adapter still sees the replay attempt
(2 calls); the waiter fails cleanly; the isolate never crashes. Caveat:
with multiple files where a *later* one is broken, the zone error can fire
after the post-fetch check — still absorbed by the guarded zone (no
crash), but the waiter may receive a lenient 200 instead of a rejection.
Single-file uploads (the overwhelmingly common case) reject correctly.

---

## Failure memo + determinism round (2026-09-30, post-Batch-B fixes)

### Terminal-failure memo — decision

**Chosen: memoize only non-retryable failures** (`AuthRefreshException` with
`retryable == false`, which is the default — including the guard's own
`'no refresh token'` and `'session changed during refresh'` paths).
Transient failures — refresh timeouts and any non-`AuthRefreshException`
thrown by the refresher (network errors) — are **never memoized**: the next
401 starts a fresh cycle. A cooldown was considered and rejected: the guard
cannot reliably classify arbitrary refresher exceptions, and a cooldown that
is short enough to self-heal quickly is also short enough to re-open the
failure storm.

Mechanics (`lib/src/auth_refresh_interceptor.dart`):

* `_failedForToken` / `_terminalFailure` are written in `_refreshTask`'s
  single catch when the original error is terminal.
* `onError` consults the memo only when the provider's current access token
  **equals** the request's sent token (`current == sent`); a changed token
  takes the fast-replay path instead. Memo hits reject with the memoized
  `AuthRefreshException` — no refresher, no second `onAuthFailed`.
* A successful cycle clears the memo.
* `AuthRefreshException` gained a `retryable` flag (default `false`) so
  refreshers can opt a guard-exception into the transient category.

### Null-refresh-token path — answered

**Today (before this round): yes**, the `'no refresh token'` failure flowed
through the shared catch and called `onAuthFailed`. In a logout-straggler
scenario with the pre-fix code, each straggler 401 started its own cycle,
each hit `'no refresh token'`, and each re-fired `onAuthFailed`: for the
original cycle plus *N* stragglers that is **1 + N calls** (and 1 + N
refresher calls). After this round, a new **session-ended** check in
`onError` (sent token existed, provider's current token is `null`) rejects
stragglers before any refresh and **without `onAuthFailed`**, so the total
stays at exactly **1** — the original cycle only (covered by
`stragglers after logout: session-ended path, no extra refresh or
onAuthFailed`).

### Dio source citation — `CancelToken.requestOptions` never assigned

From the installed `dio 5.11.1`
(`%LOCALAPPDATA%\Pub\Cache\hosted\pub.dev\dio-5.11.1`):

* `lib/src/cancel_token.dart:29` — `RequestOptions? requestOptions;`
  (the only write to this field is the declaration; nobody assigns it).
* `lib/src/cancel_token.dart:55-56` — `cancel()` builds the error via
  `DioException.requestCancelled(requestOptions: requestOptions ?? RequestOptions(), ...)`
  — hence **empty** options when unassigned.
* Package-wide grep for `(cancelToken|token)\.requestOptions\s*=` —
  **0 matches** in the entire `lib/` tree: neither `DioMixin`
  (`lib/src/dio_mixin.dart`) nor any adapter assigns it.

Consequence: cancel errors delivered by dio carry no `extra`/headers; the
guard's own `awaitWithCancel` builds its cancel `DioException` with the
waiter's real `RequestOptions`, so mid-refresh cancellations are unaffected.
The cancellation-during-replay test asserts `DioExceptionType.cancel` plus
adapter call counts instead of `extra` flags.

### Test determinism

All 20–300 ms sleeps and the <250 ms stopwatch bound were removed.
Coordination is now Completer-gated:

* **Gated refreshers** — the refresher awaits a `Completer` the test
  completes (first call gated, later calls instant in the memo suite).
* **Gated adapters** — per-request `Completer` gates hold back specific 401
  responses (straggler/logout/replay scenarios).
* **`pumpEventQueue(times: N)`** (built-in from `package:test`) replaces
  fixed sleeps to let dio's interceptor pipelines advance; each interceptor
  wrapper step is one `Future(...)` = one event turn, so bounded turn counts
  are clock-free.
* The only real-time bound left is the timeout tests' 1 s
  `refreshTimeout` (spec: bounds must be ≥ 1 s), each with a 10 s test
  timeout.

### Characterization — instant (zero-delay) refreshes after the memo

* **Terminal failure:** the memo closes the herding hole — N concurrent
  waiters, instant terminal-failing refresher → exactly 1 refresher call
  and 1 `onAuthFailed` total (test locks this in).
* **Transient failure:** still bounded per-waiter churn — N waiters, instant
  transient-failing refresher → N refresher calls, N `onAuthFailed` calls,
  all waiters still rejected cleanly, no hang (test documents this as the
  accepted trade-off; real refreshes always span ≥ 1 event turn).

---

## Terminal vs transient classification round (2026-10-01, pre-packaging)

### `isTerminalRefreshError` — decision

`onAuthFailed` fires **only for terminal failures**. Transient failures
(timeouts, connection errors, 5xx refresh responses) reject waiters with
`AuthRefreshException(retryable: true)` and never fire `onAuthFailed` or get
memoized — the next 401 starts a fresh cycle.

`AuthRefreshConfig.isTerminalRefreshError` (fully overrideable; the override
is consulted for **every** error kind, including `AuthRefreshException`)
defaults to:

| Error | Classified |
|-------|-----------|
| `AuthRefreshException` | terminal iff `!retryable` (covers the guard's own `'no refresh token'` / `'session changed'`) |
| `DioException` with response 400 / 401 / 403 | terminal |
| `DioException` type `connectionTimeout` / `sendTimeout` / `receiveTimeout` / `connectionError` | transient |
| `DioException` with any 5xx response | transient |
| `TimeoutException` | transient |
| anything else | transient |

Memoization: unchanged mechanics (keyed by sent access token, cleared on
success / token change) but **terminal-only**. Covered by the
`terminal vs transient classification` test group (401/400/403 terminal +
memoized; 503 and connectionError transient + retried; custom override
respected; timeout never fires `onAuthFailed`).

### `abandoned` double-check

`_refreshTask` re-checks `abandoned` **immediately before `setTokens`**
(after the session re-read await) — a timeout firing during that await must
not persist tokens. Covered by
`timeout during the session re-read: setTokens is never called`, which uses
a `_SecondReadGatedProvider` blocking the second `getRefreshToken` call so
the timeout provably fires mid-await.

### SDK / dio minimums — what was verified

* Private named initializing formals were **removed** from the
  `AuthRefreshInterceptor` constructor (classic `required Dio dio` +
  initializer list, one `// ignore_for_file: prefer_initializing_formals`).
  The library uses no language features beyond null-safety era Dart 3
  (no records/patterns/class modifiers), so `environment: sdk: ^3.3.0` is
  declared per decision. **Verified:** resolution, `dart analyze` and the
  full suite (72 tests) pass on the installed Dart 3.13.2 with the
  constraint set to `^3.3.0`; no 3.3.0 toolchain was available here to
  compile on directly.
* **dio floor = `^5.5.0`**, determined empirically:
  * `5.0.0` — fails to compile: no `DioException`/`DioExceptionType`
    (added in 5.2.0), no `FormData.clone`/`MultipartFile.fromStream`
    (added in 5.3.1).
  * `5.3.1`, `5.4.0` — compile but the non-replayable `FormData` replay
    test **hangs 30 s**: in these versions `FormData.finalize()` drives the
    file loop via `Future.forEach(...).then((_) => controller.close())`
    with no error handling, so an already-listened file stream error
    leaves the controller open forever (verified in the 5.3.1/5.4.0
    sources, `form_data.dart` ~line 161). dio 5.5.0 restructured the loop
    with `whenComplete` closing the controller on error.
  * `5.5.0` — full suite passes (72/72) and `dart analyze` is clean with
    `dart pub downgrade dio`.
  * After pinning `^5.5.0`: `dart pub upgrade` restores 5.11.1.
* Plain `dart pub downgrade` (all dev transitive floors) still analyzes
  clean, but the test **loader** fails on this machine
  (`Could not find ...dart.snapshot`): the floored dev toolchain
  (`test_core 0.6.20` → `frontend_server_client 3.2.0`) predates the
  Dart 3.13.2 SDK install layout. Dev-only, unrelated to the package or
  dio; consumers are unaffected.

### Guarded-zone FormData replay — misattribution caveat

`_replayFetch` runs FormData replays inside `runZonedGuarded` because
dio's `FormData.finalize()` fire-and-forgets its internal write loop, so a
non-replayable stream factory surfaces as an *unhandled zone* error that
the guard converts into a clean `AuthRefreshException` rejection.

**Caveat (documented in the `_replayFetch` dartdoc too):** the guarded
zone captures **all** uncaught async errors that fire while the replayed
request is in flight — including errors escaping unrelated user
interceptors or other request-pipeline code — and can misattribute them
as FormData replay failures. If the guard rejects a FormData replay with
an unexpected cause, check other interceptors first.

### Packaging

* `example/main.dart` — runnable fully offline (`dart run
  example/main.dart`): a fake adapter serves `/me` (401 unless the
  current valid token is attached) and `/auth/refresh` (rotating
  single-use refresh tokens). Output: 3 concurrent stale-token requests →
  all 200 after exactly **1** refresh call.
* `CHANGELOG.md` written for 0.1.0.
* pubspec: description (83 chars, within 60–180), repository +
  issue_tracker from the git remote (`github.com/satr-zero/dio_single_flight`),
  5 topics.
* README: intentionally untouched — maintainer will provide the text.

---

## Phase 2 checklist

- [x] Verify `RequestOptions.copyWith` / `FormData.clone` / `CancelToken.whenCancel` in the real package (results above).
- [x] Apply all 8 fixes above to `auth_refresh_interceptor.dart` (Batch B, 2026-09-30).
- [x] Tests for #1 (late cancel), #3 (no token → no refresh), #8 (FormData clone wrap, through Dio + adapter), race-token and cancellation suites.
- [x] Batch A: `AuthTokens`, `TokenProvider`, `MemoryTokenProvider`, `AuthRefreshConfig` (401-only, 10 s), `AuthRefreshException`, constants, `awaitWithCancel` (+ tests).
- [x] Batch B: `AuthRefreshInterceptor` (onRequest / onError / _replay / refreshDio) + integration, race-token, replay, cancellation suites.
- [x] Failure memo (terminal non-retryable `AuthRefreshException`), session-ended rejection, `retryable` flag.
- [x] Deterministic test rewrite: Completer gates + `pumpEventQueue`, no ms-sleeps, ≥1 s timeout bounds only.
- [x] New suites: failure memo (staggered waves, logout stragglers, transient retry, timeout retry, handler-once, async `onAuthFailed`, instant-refresh characterization).
- [x] `CancelToken.requestOptions` claim verified against installed dio source (cited above).
- [x] Terminal/transient classification (`isTerminalRefreshError`), `onAuthFailed` terminal-only, `abandoned` re-check before `setTokens`.
- [x] Classic constructor formals; `sdk: ^3.3.0`; dio floor `^5.5.0` verified empirically (see above).
- [x] Zone-misattribution caveat documented (dartdoc + here).
- [x] Packaging: example, CHANGELOG, pubspec fields, publish dry-run.

Deferred to packaging phase: README rewrite, example/, CHANGELOG, pub
publish dry-run.

## Phase 1 fix applied — RefreshCoordinator sync-throw

`RefreshCoordinator.execute` now uses `await Future.sync(task)` inside the async closure, not `await task()`:

```dart
final future = () async {
  try {
    await Future.sync(task);
  } finally {
    _future = null;
  }
}();
```

Without `Future.sync`, a non-async task like `() => throw StateError('x')` throws **synchronously** during `task()` evaluation, before `_future = future` is assigned. The `finally` runs, clears `_future = null`, but `_future` was still `null` at that moment — then `_future = future` assigns a completed Future that will never be cleared, leaving a permanently failed stale `_future`. `Future.sync` captures synchronous throws into a `Future`, so `await` and `finally` ordering is correct. Test added: `non-async task that throws synchronously does not leave stale Future` (counter == 2, `isRefreshing == false` in between).

### Test count

Phase 1 report said 10 tests passed; after the sync-throw fix the suite has **11** tests. Discrepancy is 10 → 11, not 9 → 10 — the new test is the sync-throw case. `dart test` output now: `+11: All tests passed!`
