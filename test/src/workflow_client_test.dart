import 'dart:convert';
import 'package:catglobe_dev/catglobe_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('debug paths and deployed IDs share JSON parameters and decoded results',
      () async {
    final requests = <http.Request>[];
    final transport = MockClient((request) async {
      requests.add(request);
      return http.Response('{"result":{"value":42},"error":null}', 200);
    });
    addTearDown(transport.close);
    for (final debug in [true, false]) {
      final client = CatglobeWorkflowClient(
          debug: debug,
          issuer: Uri.parse('https://site.test/dashboard/7'),
          workflowIds: {'Folder/A': 123},
          client: transport,
          accessToken: () async => 'token');
      expect(await client.run('Folder/A', {'id': 7}), {'value': 42});
    }
    expect(requests[0].url.toString(),
        'http://localhost:5000/api/cgscript/run/Folder/A');
    expect(
        requests[1].url.toString(), 'https://site.test/api/cgscript/run/123');
    expect(requests.map((r) => jsonDecode(r.body)), everyElement({'id': 7}));
    expect(requests.every((r) => r.headers['Authorization'] == 'Bearer token'),
        isTrue);
  });

  test('online allows browser session auth and expandParameters', () async {
    final transport = MockClient((request) async {
      expect(request.headers.containsKey('Authorization'), isFalse);
      expect(request.url.queryParameters, {'expandParameters': 'true'});
      expect(jsonDecode(request.body), [1, 2]);
      return http.Response('{"result":null}', 200);
    });
    addTearDown(transport.close);
    final client = CatglobeWorkflowClient(
        debug: false,
        issuer: Uri.parse('https://site.test/'),
        workflowIds: {'A': 1},
        client: transport);
    expect(await client.run('A', [1, 2], expandParameters: true), isNull);
    await expectLater(client.run('Missing', {}), throwsStateError);
  });

  test('both environments preserve Catglobe script errors', () async {
    final transport = MockClient((_) async =>
        http.Response('{"result":null,"error":{"message":"failed"}}', 200));
    addTearDown(transport.close);
    for (final debug in [true, false]) {
      final client = CatglobeWorkflowClient(
          debug: debug,
          issuer: Uri.parse('https://site.test/'),
          workflowIds: {'A': 1},
          accessToken: () => 'token',
          client: transport);
      await expectLater(
          client.run('A', null), throwsA(isA<CgScriptException>()));
    }
  });
}
