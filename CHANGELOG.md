## 0.1.0

Initial release.

* **Single-flight refresh** — only one refresh call runs at a time, no
  matter how many requests fail with 401 concurrently; all failed requests
  wait for it and are replayed with the new token.
* **Safe replay** — the original `RequestOptions` is never mutated;
  `FormData` is cloned so retried uploads work. Requests that 401 again
  after a retry are passed through to the caller (no infinite loops).
* **Race guard** — a 401 arriving after a refresh already completed (its
  request was dispatched with the stale token) is replayed immediately
  without triggering a second refresh.
* **Terminal vs transient failures** — terminal failures (per
  `AuthRefreshConfig.isTerminalRefreshError`: by default
  `AuthRefreshException` with `retryable == false`, or refresh-endpoint
  400/401/403 responses) are memoized for the sent access token and fire
  `onAuthFailed` exactly once; later 401s with the same token are rejected
  with the memoized failure until the stored tokens change. Transient
  failures (timeouts, connection errors, 5xx responses) reject waiters
  with `AuthRefreshException(retryable: true)` and never fire `onAuthFailed`
  or get memoized — the next 401 starts a fresh cycle.
* **Session protection** — logout (or logout-then-login) during a refresh
  discards the stale result; 401s straggling in after a logout are
  rejected immediately without refreshing.
* **Cancellation** — a request cancelled while waiting for the refresh
  rejects immediately with `DioExceptionType.cancel`; the refresh
  continues for the remaining waiters.
* **No deadlocks** — plain `Interceptor` with a single-flight coordinator
  instead of `QueuedInterceptor` locking; refreshes run on a dedicated
  `Dio` (custom adapters, proxies and certificate pinning preserved) with
  no interceptor recursion.
