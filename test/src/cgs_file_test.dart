import 'dart:convert';
import 'package:catglobe_dev/src/cgs_file.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

class UploadClient extends http.BaseClient {
  final requests = <http.Request>[];
  final payloads = <List<int>>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final upload = request as http.Request;
    requests.add(upload);
    expect(request.followRedirects, isFalse);
    payloads.add(upload.bodyBytes);
    return http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode({
          'success': true,
          'filename': upload.url.pathSegments.last,
          'isTemp': false,
          'size': upload.bodyBytes.length,
        }))),
        201);
  }
}

void main() {
  test('raw body contract preserves bytes and uses permanent Dashboard names',
      () async {
    final client = UploadClient();
    final uploader = CgsFileUploader(client, Uri.parse('https://example.com/'),
        accessToken: () => 'token');
    final result = await uploader.upload(42, {
      'assets/font.woff2': [0, 255, 128, 1],
      'main.dart.js': [10, 20],
    });
    final name = CgsFileUploader.storageName(42, 'assets/font.woff2');
    expect(client.requests.first.method, 'POST');
    expect(client.requests.first.url.path, '/api/files/upload/$name');
    expect(client.requests.first.headers['Authorization'], 'Bearer token');
    expect(client.requests.first.url.queryParameters,
        {'overWrite': 'true', 'isTemp': 'false'});
    expect(client.requests.first.headers['Content-Type'],
        'application/octet-stream');
    expect(client.payloads.first, [0, 255, 128, 1]);
    expect(result['assets/font.woff2']!.queryParameters['file'],
        CgsFileUploader.storageName(42, 'assets/font.woff2'));
    expect(result['main.dart.js']!.path, '/CgScript/File');
  });

  test('names avoid flattened path, Unicode and Dashboard collisions', () {
    final names = [
      CgsFileUploader.storageName(42, 'a/b.js'),
      CgsFileUploader.storageName(42, 'a_b.js'),
      CgsFileUploader.storageName(43, 'a/b.js'),
      CgsFileUploader.storageName(42, 'ảnh.js'),
    ];
    expect(names.toSet().length, 4);
    expect(
        names.every((name) => RegExp(r'^\d+_[a-f0-9]{64}\.js$').hasMatch(name)),
        isTrue);
  });

  test('empty file bodies are supported', () async {
    final client = UploadClient();
    final uploader = CgsFileUploader(client, Uri.parse('https://example.com/'),
        accessToken: () => 'token');
    await uploader.upload(42, {'empty.txt': []});
    expect(client.payloads.single, isEmpty);
  });

  test('invalid paths fail before sending', () async {
    final client = UploadClient();
    final uploader = CgsFileUploader(client, Uri.parse('https://example.com/'),
        accessToken: () => 'token');
    for (final files in [
      {
        'valid.js': [1],
        '../escape.js': [2]
      },
    ]) {
      await expectLater(uploader.upload(42, files), throwsFormatException);
    }
    expect(client.requests, isEmpty);
  });

  test('rejects HTTP failures, login HTML and unconfirmed upload results',
      () async {
    for (final response in [
      http.Response('redirect', 302),
      http.Response('<html>Login</html>', 200),
      http.Response('{"success":false}', 200),
      http.Response('{"success":true,"name":"wrong"}', 200),
    ]) {
      final client = MockClient((_) async => response);
      final uploader = CgsFileUploader(
          client, Uri.parse('https://example.com/'),
          accessToken: () => 'token');
      await expectLater(
          uploader.upload(42, {
            'main.js': [1]
          }),
          throwsA(anyOf(isA<StateError>(), isA<FormatException>())));
      client.close();
    }
  });
}
