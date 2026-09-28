import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/core/models/hermes_models.dart';
import 'package:hermes_mobile/core/network/dashboard_client.dart';

class _MediaAdapter implements HttpClientAdapter {
  RequestOptions? request;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
    return ResponseBody.fromString(
      jsonEncode({'dataUrl': 'data:image/png;base64,AA=='}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('generated image uses the authenticated filesystem bridge', () async {
    final adapter = _MediaAdapter();
    final dio = Dio(
      BaseOptions(
        baseUrl: 'https://gw.test',
        validateStatus: (status) => status != null && status < 500,
      ),
    )..httpClientAdapter = adapter;
    final client = DashboardClient(
      profile: const ConnectionProfile(id: 'gw', baseUrl: 'https://gw.test'),
      dio: dio,
    );

    final data = await client.readGeneratedImage(
      '/home/me/.hermes/cache/images/cat.png',
      profileName: 'artist',
      sessionId: 'session-1',
    );

    expect(data, 'data:image/png;base64,AA==');
    expect(adapter.request?.path, '/api/fs/read-data-url');
    expect(
      adapter.request?.queryParameters['path'],
      '/home/me/.hermes/cache/images/cat.png',
    );
    expect(adapter.request?.queryParameters['profile'], 'artist');
    expect(adapter.request?.queryParameters['session_id'], 'session-1');
  });
}
