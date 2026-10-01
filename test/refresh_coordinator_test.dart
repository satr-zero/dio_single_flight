import 'dart:async';

import 'package:dio_single_flight/dio_single_flight.dart';
import 'package:test/test.dart';

void main() {
  group('RefreshCoordinator', () {
    test('single call executes task exactly once', () async {
      final c = RefreshCoordinator();
      var count = 0;
      await c.execute(() async {
        count++;
      });
      expect(count, 1);
      expect(c.isRefreshing, isFalse);
    });

    test('10 concurrent callers share one execution', () async {
      final c = RefreshCoordinator();
      var count = 0;
      final gate = Completer<void>();
      final futures = List.generate(10, (_) {
        return c.execute(() async {
          count++;
          await gate.future;
        });
      });
      // While in-flight, isRefreshing should be true.
      expect(c.isRefreshing, isTrue);
      gate.complete();
      await Future.wait(futures);
      expect(
        count,
        1,
        reason: 'task must run only once for 10 concurrent callers',
      );
      expect(c.isRefreshing, isFalse);
    });

    test('failure reaches all waiters', () async {
      final c = RefreshCoordinator();
      var count = 0;
      final gate = Completer<void>();
      final futures = List.generate(10, (_) {
        return c.execute(() async {
          count++;
          await gate.future;
          throw StateError('refresh failed');
        });
      });
      expect(c.isRefreshing, isTrue);
      gate.complete();
      for (final f in futures) {
        await expectLater(f, throwsA(isA<StateError>()));
      }
      expect(count, 1);
      expect(c.isRefreshing, isFalse);
    });

    test('next call after failure starts a fresh refresh', () async {
      final c = RefreshCoordinator();
      var count = 0;

      await expectLater(
        c.execute(() async {
          count++;
          throw StateError('first fail');
        }),
        throwsA(isA<StateError>()),
      );
      expect(count, 1);
      expect(c.isRefreshing, isFalse);

      // Second cycle should run task again, not return stale error.
      await c.execute(() async {
        count++;
      });
      expect(count, 2);

      // Third cycle fails again with different error — must be fresh.
      await expectLater(
        c.execute(() async {
          count++;
          throw ArgumentError('second fail');
        }),
        throwsA(isA<ArgumentError>()),
      );
      expect(count, 3);
    });

    test(
        'new caller arriving right after completion starts fresh (no stale Future)',
        () async {
      final c = RefreshCoordinator();

      // First refresh succeeds.
      await c.execute(() async {
        await Future<void>.delayed(Duration.zero);
      });
      expect(c.isRefreshing, isFalse);

      // Immediately after completion, a new caller must trigger a fresh task.
      var secondRan = false;
      var thirdRan = false;

      await c.execute(() async {
        secondRan = true;
        throw StateError('second refresh fails');
      }).catchError((_) {});
      expect(secondRan, isTrue);
      expect(c.isRefreshing, isFalse);

      // After a failing second cycle, third must still be fresh.
      await c.execute(() async {
        thirdRan = true;
      });
      expect(thirdRan, isTrue);
    });

    test('new caller after success does not receive stale success', () async {
      final c = RefreshCoordinator();
      var runCount = 0;

      await c.execute(() async {
        runCount++;
      });
      expect(runCount, 1);

      // If stale, this would return immediately with old success and
      // runCount stays 1.
      await c.execute(() async {
        runCount++;
        await Future<void>.delayed(Duration.zero);
      });
      expect(runCount, 2);

      // Verify with failure-then-success sequence too.
      await expectLater(
        c.execute(() async {
          runCount++;
          throw Exception('boom');
        }),
        throwsException,
      );
      expect(runCount, 3);

      await c.execute(() async {
        runCount++;
      });
      expect(
        runCount,
        4,
        reason:
            'after failure, next caller must start fresh, not get stale error',
      );
    });

    test(
      'runZonedGuarded: single waiter failure produces zero uncaught errors',
      () async {
        final uncaught = <Object>[];
        await runZonedGuarded(
          () async {
            final c = RefreshCoordinator();
            await expectLater(
              c.execute(() async => throw StateError('fail')),
              throwsA(isA<StateError>()),
            );
            await pumpEventQueue(times: 20);
          },
          (Object e, StackTrace s) {
            uncaught.add(e);
          },
        );
        await pumpEventQueue(times: 20);
        expect(
          uncaught,
          isEmpty,
          reason: 'no unhandled async error should leak',
        );
      },
    );

    test(
      'runZonedGuarded: many waiters failure produces zero uncaught errors',
      () async {
        final uncaught = <Object>[];
        await runZonedGuarded(
          () async {
            final c = RefreshCoordinator();
            final gate = Completer<void>();
            final futures = List.generate(10, (_) {
              return c.execute(() async {
                await gate.future;
                throw StateError('fail');
              });
            });
            gate.complete();
            for (final f in futures) {
              await expectLater(f, throwsA(isA<StateError>()));
            }
            await pumpEventQueue(times: 20);
          },
          (Object e, StackTrace s) {
            uncaught.add(e);
          },
        );
        await pumpEventQueue(times: 20);
        expect(uncaught, isEmpty);
      },
    );

    test(
      'non-async task that throws synchronously does not leave stale Future',
      () async {
        final c = RefreshCoordinator();
        var count = 0;

        Future<void> syncThrow() {
          count++;
          throw StateError('sync fail');
        }

        await expectLater(c.execute(syncThrow), throwsA(isA<StateError>()));
        expect(count, 1);
        expect(
          c.isRefreshing,
          isFalse,
          reason: 'finally must have cleared _future',
        );

        // Second call must run a fresh task, not return stale error.
        await c.execute(() async {
          count++;
        });
        expect(count, 2);
        expect(c.isRefreshing, isFalse);
      },
    );

    test('isRefreshing reflects in-flight state', () async {
      final c = RefreshCoordinator();
      expect(c.isRefreshing, isFalse);
      final gate = Completer<void>();
      final future = c.execute(() async {
        await gate.future;
      });
      expect(c.isRefreshing, isTrue);
      gate.complete();
      await future;
      expect(c.isRefreshing, isFalse);
    });

    test('success with many waiters — all complete', () async {
      final c = RefreshCoordinator();
      var count = 0;
      final gate = Completer<void>();
      final futures = List.generate(10, (_) {
        return c.execute(() async {
          count++;
          await gate.future;
        });
      });
      gate.complete();
      await Future.wait(futures);
      expect(count, 1);
    });
  });
}
