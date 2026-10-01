/// Single-flight coordinator for token refresh.
///
/// Guarantees that only one [task] runs at a time. Concurrent callers that
/// arrive while a refresh is in-flight share the same [Future].
///
/// Uses the same-Future reset form so that [_future] is cleared *inside*
/// the same Future that callers await. This avoids the stale-Future race
/// where a fire-and-forget wrapper clears [_future] in a later microtask
/// and a new caller briefly sees a completed (stale) Future.
class RefreshCoordinator {
  Future<void>? _future;

  /// Whether a refresh is currently in-flight.
  bool get isRefreshing => _future != null;

  /// Executes [task] with single-flight semantics.
  ///
  /// If no refresh is in-flight, starts [task] and returns its Future.
  /// If a refresh is already in-flight, returns the existing Future so
  /// all waiters share it.
  Future<void> execute(Future<void> Function() task) {
    final existing = _future;
    if (existing != null) return existing;

    final future = () async {
      try {
        await Future.sync(task);
      } finally {
        _future = null;
      }
    }();

    _future = future;
    return future;
  }
}
