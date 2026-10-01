import 'dart:async';

import 'package:dio/dio.dart';
import 'package:dio_single_flight/dio_single_flight.dart';
import 'package:test/test.dart';

void main() {
  RequestOptions options() => RequestOptions(path: '/test');

  group('awaitWithCancel', () {
    test('null token returns the same future', () async {
      final completer = Completer<void>();
      final result = awaitWithCancel(completer.future, null, options());
      expect(result, same(completer.future));
      completer.complete();
      await result;
    });

    test('null token propagates coordinator failure', () async {
      final completer = Completer<void>();
      completer.completeError(StateError('fail'));
      final result = awaitWithCancel(completer.future, null, options());
      await expectLater(result, throwsA(isA<StateError>()));
    });

    test('no cancellation — coordinator success passes through', () async {
      final token = CancelToken();
      final completer = Completer<void>();
      final guarded = awaitWithCancel(completer.future, token, options());
      completer.complete();
      await guarded;
    });

    test('no cancellation — coordinator failure passes through', () async {
      final token = CancelToken();
      final completer = Completer<void>();
      final guarded = awaitWithCancel(completer.future, token, options());
      completer.completeError(StateError('refresh failed'));
      await expectLater(guarded, throwsA(isA<StateError>()));
    });

    test(
      'cancel before coordinator completes throws cancel DioException',
      () async {
        final token = CancelToken();
        // The coordinator future never completes — only the cancel can win.
        final guarded = awaitWithCancel(
          Completer<void>().future,
          token,
          options(),
        );

        token.cancel('stop');

        try {
          await guarded;
          fail('should have thrown');
        } on DioException catch (e) {
          expect(e.type, DioExceptionType.cancel);
          expect(e.error, isA<DioException>());
          expect((e.error! as DioException).type, DioExceptionType.cancel);
          expect(e.requestOptions.path, '/test');
        }
        expect(token.isCancelled, isTrue);
      },
    );

    test('late cancel after success produces no uncaught error', () async {
      final uncaught = <Object>[];
      await runZonedGuarded(() async {
        final token = CancelToken();
        final completer = Completer<void>();
        final guarded = awaitWithCancel(completer.future, token, options());
        completer.complete();
        await guarded;
        token.cancel('late');
        await pumpEventQueue(times: 20);
      }, (e, s) => uncaught.add(e));
      await pumpEventQueue(times: 20);
      expect(uncaught, isEmpty);
    });

    test(
      'coordinator failure after cancellation produces no uncaught error',
      () async {
        final uncaught = <Object>[];
        await runZonedGuarded(() async {
          final token = CancelToken();
          final completer = Completer<void>();
          final guarded = awaitWithCancel(completer.future, token, options());

          token.cancel('stop');
          await expectLater(guarded, throwsA(isA<DioException>()));

          // The coordinator fails AFTER the cancel already won.
          completer.completeError(StateError('refresh failed later'));
          await pumpEventQueue(times: 20);
        }, (e, s) => uncaught.add(e));
        await pumpEventQueue(times: 20);
        expect(uncaught, isEmpty);
      },
    );

    test('cancel after failure produces no uncaught error', () async {
      final uncaught = <Object>[];
      await runZonedGuarded(() async {
        final token = CancelToken();
        final completer = Completer<void>();
        final guarded = awaitWithCancel(completer.future, token, options());
        completer.completeError(StateError('refresh failed'));
        await expectLater(guarded, throwsA(isA<StateError>()));
        token.cancel('late');
        await pumpEventQueue(times: 20);
      }, (e, s) => uncaught.add(e));
      await pumpEventQueue(times: 20);
      expect(uncaught, isEmpty);
    });
  });
}
