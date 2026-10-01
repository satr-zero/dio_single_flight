import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:dio_single_flight/dio_single_flight.dart';
import 'package:test/test.dart';

import 'helpers/fake_adapter.dart';

void main() {
  group('replay', () {
    late Dio dio;
    late FakeAdapter adapter;
    late MemoryTokenProvider provider;

    setUp(() {
      adapter = FakeAdapter();
      dio = Dio(BaseOptions(baseUrl: 'https://example.com'))
        ..httpClientAdapter = adapter;
      provider = MemoryTokenProvider(accessToken: 'A', refreshToken: 'rt1');
      dio.interceptors.add(
        AuthRefreshInterceptor(
          dio: dio,
          tokenProvider: provider,
          refresher: (refreshToken, refreshDio) async =>
              const AuthTokens(accessToken: 'B', refreshToken: 'rt2'),
        ),
      );
    });

    void stubAuthBehavior() {
      adapter.setHandler((options) async {
        final auth = options.headers['Authorization'];
        if (auth == 'Bearer A') {
          return jsonResponse({'error': 'unauthorized'}, status: 401);
        }
        return jsonResponse({'ok': true, 'token': auth});
      });
    }

    test(
      'queryParameters, custom headers and contentType are preserved',
      () async {
        stubAuthBehavior();

        final res = await dio.get<Map<String, dynamic>>(
          '/protected',
          queryParameters: {'page': 2, 'sort': 'desc'},
          options: Options(
            headers: {'X-Custom': 'yes'},
            contentType: 'application/json',
          ),
        );
        expect(res.statusCode, 200);

        final replayed = adapter.calls[1];
        expect(replayed.uri.queryParameters['page'], '2');
        expect(replayed.uri.queryParameters['sort'], 'desc');
        expect(replayed.headers['X-Custom'], 'yes');
        expect(
          replayed.headers['Authorization'],
          'Bearer B',
          reason: 'onRequest overwrote the stale token',
        );
        expect(replayed.contentType, 'application/json');
      },
    );

    test('original RequestOptions is not mutated by _replay', () async {
      stubAuthBehavior();

      // Capture the options of the first (401) call.
      RequestOptions? original;
      adapter.setHandler((options) async {
        if (original == null &&
            options.headers['Authorization'] == 'Bearer A') {
          original = options;
        }
        final auth = options.headers['Authorization'];
        if (auth == 'Bearer A') {
          return jsonResponse({'error': 'unauthorized'}, status: 401);
        }
        return jsonResponse({'ok': true});
      });

      await dio.get<Map<String, dynamic>>('/protected');

      final first = adapter.calls[0];
      expect(
        first.extra.containsKey(kRetryKey),
        isFalse,
        reason: 'retry flag must only exist on the replay copy',
      );
      expect(adapter.calls[1].extra[kRetryKey], isTrue);
    });

    test(
      'FormData with fromBytes file: clone succeeds and replays through Dio',
      () async {
        stubAuthBehavior();

        final formData = FormData()
          ..fields.add(const MapEntry('key', 'value'))
          ..files.add(
            MapEntry(
              'file',
              MultipartFile.fromString('hello upload', filename: 'a.txt'),
            ),
          );

        final res = await dio.post<Map<String, dynamic>>(
          '/upload',
          data: formData,
        );
        expect(res.statusCode, 200);
        expect(adapter.calls.length, 2, reason: 'original + replayed upload');

        final replayedBody = utf8.decode(adapter.bodies[1]);
        expect(
          replayedBody,
          contains('value'),
          reason: 'fields survive replay',
        );
        expect(
          replayedBody,
          contains('a.txt'),
          reason: 'filename survives replay',
        );
        expect(
          adapter.calls[1].headers['Authorization'],
          'Bearer B',
          reason: 'replayed with the refreshed token',
        );
      },
    );

    test(
        'FormData with a non-replayable fromStream factory: clean '
        'AuthRefreshException rejection, no crash', () async {
      stubAuthBehavior();

      // A factory that reuses the same single-subscription stream: the
      // first send consumes it, the replayed clone cannot re-listen.
      // close() is NOT awaited: without a listener its future never
      // completes (buffered events wait for the first subscription).
      final controller = StreamController<List<int>>()
        ..add([1, 2, 3, 4])
        ..close();
      final sharedStream = controller.stream;
      final formData = FormData()
        ..files.add(
          MapEntry(
            'file',
            MultipartFile.fromStream(() => sharedStream, 4, filename: 'a.bin'),
          ),
        );

      final uncaught = <Object>[];
      late Object waiterError;
      await runZonedGuarded(() async {
        try {
          await dio.post<Map<String, dynamic>>('/upload', data: formData);
          waiterError = StateError('should have thrown');
        } catch (e) {
          waiterError = e;
        }
        // Let every late stream error surface.
        await pumpEventQueue(times: 10);
      }, (e, s) => uncaught.add(e));

      expect(waiterError, isA<DioException>());
      final de = waiterError as DioException;
      expect(
        de.error,
        isA<AuthRefreshException>(),
        reason: 'stream failure must be wrapped, not leak',
      );
      expect(
        (de.error! as AuthRefreshException).message,
        contains('cannot produce a fresh stream'),
      );
      // The error from dio's internal FormData write loop must not escape
      // as an unhandled zone error (it is captured by the guarded replay).
      expect(
        uncaught.where((e) => e.toString().contains('already been listened')),
        isEmpty,
        reason: 'guarded zone must absorb the dio-internal stream error',
      );
      expect(
        adapter.calls.length,
        2,
        reason: 'the replay was attempted through Dio',
      );
    });
  });
}
