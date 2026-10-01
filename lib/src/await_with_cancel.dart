import 'dart:async';

import 'package:dio/dio.dart';

/// Races [coordinatorFuture] against the cancellation of [token].
///
/// When [token] is null, returns [coordinatorFuture] as-is.
///
/// Implemented with a single [Completer] gated by `isCompleted` so that
/// exactly one outcome wins. The losing side is always observed (and
/// ignored), which guarantees:
///
/// * no unhandled async error when the cancellation wins and the refresh
///   later fails;
/// * no unhandled async error when the refresh succeeds first and the
///   request is cancelled later (e.g. after the replay finished).
///
/// [CancelToken.whenCancel] is a `Future<DioException>` that completes with
/// the cancellation error — the thrown [DioException] here wraps it in
/// `error` and uses the original [requestOptions].
Future<void> awaitWithCancel(
  Future<void> coordinatorFuture,
  CancelToken? token,
  RequestOptions requestOptions,
) {
  if (token == null) return coordinatorFuture;

  final completer = Completer<void>();

  token.whenCancel.then((DioException cancelError) {
    if (!completer.isCompleted) {
      completer.completeError(
        DioException(
          requestOptions: requestOptions,
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
