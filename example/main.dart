import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio_single_flight/dio_single_flight.dart';

/// A fully offline fake API served by a custom [HttpClientAdapter].
///
/// * `GET /me` answers 401 unless the request carries the current valid
///   access token.
/// * `POST /auth/refresh` rotates the tokens — exactly what a refresh
///   endpoint does.
class _FakeApi implements HttpClientAdapter {
  var _validAccessToken = 'fresh-token';
  var _validRefreshToken = 'refresh-1';

  int meCalls = 0;
  int refreshCalls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path == '/auth/refresh') {
      refreshCalls++;
      // Simulate rotation: the old refresh token is single-use.
      if (requestStream != null) {
        final builder = BytesBuilder(copy: false);
        await for (final chunk in requestStream) {
          builder.add(chunk);
        }
        if (!utf8.decode(builder.takeBytes()).contains(_validRefreshToken)) {
          return _json({'error': 'invalid refresh token'}, status: 401);
        }
      }
      _validAccessToken = 'fresh-token';
      _validRefreshToken = 'refresh-2';
      return _json({
        'accessToken': _validAccessToken,
        'refreshToken': _validRefreshToken,
      });
    }
    if (options.path == '/me') {
      meCalls++;
      final auth = options.headers['Authorization'];
      if (auth != 'Bearer $_validAccessToken') {
        return _json({'error': 'token expired'}, status: 401);
      }
      return _json({'user': 'alice'});
    }
    return _json({'error': 'not found'}, status: 404);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object? data, {int status = 200}) {
  return ResponseBody.fromString(
    jsonEncode(data),
    status,
    headers: {
      Headers.contentTypeHeader: ['application/json']
    },
  );
}

Future<void> main() async {
  final api = _FakeApi();
  final dio = Dio(BaseOptions(baseUrl: 'https://demo.local'))
    ..httpClientAdapter = api;

  // The app starts with a stale access token — every request 401s until
  // the guard refreshes it.
  final provider = MemoryTokenProvider(
    accessToken: 'stale-token',
    refreshToken: 'refresh-1',
  );

  dio.interceptors.add(
    AuthRefreshInterceptor(
      dio: dio,
      tokenProvider: provider,
      refresher: (refreshToken, refreshDio) async {
        final res = await refreshDio.post<Map<String, dynamic>>(
          '/auth/refresh',
          data: {'refreshToken': refreshToken},
        );
        return AuthTokens(
          accessToken: res.data!['accessToken'] as String,
          refreshToken: res.data!['refreshToken'] as String,
        );
      },
      onAuthFailed: (cause) => print('onAuthFailed: $cause'),
      config: const AuthRefreshConfig(refreshTimeout: Duration(seconds: 5)),
    ),
  );

  print('Firing 3 concurrent requests with a stale token...');
  final responses = await Future.wait(
    List.generate(3, (_) => dio.get<Map<String, dynamic>>('/me')),
  );

  for (final res in responses) {
    print('  /me -> ${res.statusCode} ${res.data}');
  }

  print('A single refresh handled all three: ${api.refreshCalls} call(s)');
  print('New tokens persisted: access=${provider.accessToken}, '
      'refresh=${provider.refreshToken}');
}
