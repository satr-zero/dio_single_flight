import 'package:dio/dio.dart';
import 'package:dio_single_flight/dio_single_flight.dart';
import 'package:test/test.dart';

void main() {
  group('AuthRefreshConfig defaults', () {
    const config = AuthRefreshConfig();

    DioException errWithStatus(int? status) {
      final ro = RequestOptions(path: '/t');
      final response = status == null
          ? null
          : Response(requestOptions: ro, statusCode: status, data: null);
      return DioException(
        requestOptions: ro,
        response: response,
        type: DioExceptionType.badResponse,
      );
    }

    test('shouldRefresh triggers on 401 only', () {
      expect(config.shouldRefresh(errWithStatus(401)), isTrue);
      expect(config.shouldRefresh(errWithStatus(400)), isFalse);
      expect(config.shouldRefresh(errWithStatus(403)), isFalse);
      expect(config.shouldRefresh(errWithStatus(500)), isFalse);
    });

    test('shouldRefresh ignores errors without a response', () {
      final err = DioException(
        requestOptions: RequestOptions(path: '/t'),
        type: DioExceptionType.connectionError,
      );
      expect(config.shouldRefresh(err), isFalse);
    });

    test('shouldAttach defaults to true for any request', () {
      expect(config.shouldAttach(RequestOptions(path: '/a')), isTrue);
      expect(config.shouldAttach(RequestOptions(path: '/auth/login')), isTrue);
    });

    test('refreshTimeout defaults to 10 seconds', () {
      expect(config.refreshTimeout, const Duration(seconds: 10));
    });

    test('custom values are respected', () {
      const config = AuthRefreshConfig(refreshTimeout: Duration(seconds: 3));
      expect(config.refreshTimeout, const Duration(seconds: 3));
    });
  });

  group('AuthRefreshException', () {
    test('toString includes message and cause', () {
      const e1 = AuthRefreshException('refresh failed');
      expect(e1.toString(), 'AuthRefreshException: refresh failed');
      const e2 = AuthRefreshException(
        'timed out',
        cause: 'TimeoutException: 10s',
      );
      expect(e2.toString(), contains('timed out'));
      expect(e2.toString(), contains('TimeoutException: 10s'));
      expect(e2.cause, 'TimeoutException: 10s');
    });
  });

  group('constants', () {
    test('extra keys are namespaced', () {
      expect(kRetryKey, '__dio_single_flight_retry__');
      expect(kTokenKey, '__dio_single_flight_token__');
    });
  });
}
