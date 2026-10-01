import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// Handler invoked by [FakeAdapter.fetch] for every request.
typedef FakeAdapterHandler = Future<ResponseBody> Function(
  RequestOptions options,
);

/// A custom [HttpClientAdapter] stub that records every call and delegates
/// responses to a configurable handler. Used instead of a real network.
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter([FakeAdapterHandler? handler]) : _handler = handler;

  FakeAdapterHandler? _handler;

  /// All requests seen by the adapter, in order.
  final calls = <RequestOptions>[];

  /// Raw body bytes per call (decoded), aligned with [calls].
  final bodies = <List<int>>[];

  void setHandler(FakeAdapterHandler handler) {
    _handler = handler;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(options);
    final builder = BytesBuilder(copy: false);
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        builder.add(chunk);
      }
    }
    bodies.add(builder.takeBytes());
    final handler = _handler;
    if (handler == null) {
      throw StateError('FakeAdapter: no handler set');
    }
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

/// Convenience helper producing a JSON [ResponseBody].
ResponseBody jsonResponse(Object? data, {int status = 200}) {
  return ResponseBody.fromString(
    jsonEncode(data),
    status,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );
}

/// Awaits [future]; returns `null` on success or the thrown error object.
Future<Object?> outcome<T>(Future<T> future) async {
  try {
    await future;
    return null;
  } catch (e) {
    return e;
  }
}
