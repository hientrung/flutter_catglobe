import 'dart:convert';
import 'package:catglobe/catglobe_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  for (final debug in [true, false]) {
    test('omitted and null parameters send an empty array (debug: $debug)',
        () async {
      final bodies = <String>[];
      final transport = MockClient((request) async {
        bodies.add(request.body);
        return http.Response('{"result":"name"}', 200);
      });
      addTearDown(transport.close);
      final client = CgScriptClient(
          debug: debug,
          issuer: Uri.parse('https://site.test/'),
          workflowIds: {'A': 1},
          accessToken: () => 'token',
          client: transport);
      expect(await client.run('A'), 'name');
      expect(await client.run('A', parameter: null), 'name');
      expect(await client.run('A', expandParameters: true), 'name');
      expect(bodies, ['[]', '[]', '[]']);
    });
  }

  test(
      'concurrent first runs share a token lookup and failed lookup can recover',
      () async {
    var reads = 0;
    final transport = MockClient((request) async {
      if (request.method == 'GET') {
        reads++;
        await Future<void>.delayed(Duration(milliseconds: 10));
        if (reads == 1) return http.Response('unavailable', 503);
        return http.Response('{"devApiToken":"local"}', 200);
      }
      expect(request.headers['X-Cg-Token'], 'local');
      return http.Response('{"result":42}', 200);
    });
    addTearDown(transport.close);
    final client = CgScriptClient(debug: true, client: transport);
    await expectLater(
        Future.wait([
          client.run('A', parameter: null),
          client.run('B', parameter: null)
        ]),
        throwsStateError);
    expect(reads, 1);
    expect(
        await Future.wait([
          client.run('A', parameter: null),
          client.run('B', parameter: null)
        ]),
        [42, 42]);
    expect(reads, 2);
  });

  test(
      'server restart refreshes cached token once without retrying script errors',
      () async {
    var reads = 0;
    var posts = 0;
    var restarted = false;
    var scriptError = false;
    final transport = MockClient((request) async {
      if (request.method == 'GET') {
        reads++;
        return http.Response(
            jsonEncode({'devApiToken': restarted ? 'new' : 'old'}), 200);
      }
      posts++;
      if (restarted && request.headers['X-Cg-Token'] == 'old') {
        return http.Response('{"error":"Request forbidden"}', 403);
      }
      expect(jsonDecode(request.body), [1, 2]);
      expect(request.url.queryParameters['expandParameters'], 'true');
      if (scriptError) return http.Response('{"error":"script denied"}', 403);
      return http.Response('{"result":42}', 200);
    });
    addTearDown(transport.close);
    final client = CgScriptClient(debug: true, client: transport);
    expect(
        await client.run('A', parameter: [1, 2], expandParameters: true), 42);
    restarted = true;
    expect(
        await client.run('A', parameter: [1, 2], expandParameters: true), 42);
    expect(reads, 2);
    expect(posts, 3);
    scriptError = true;
    await expectLater(
        client.run('A', parameter: [1, 2], expandParameters: true),
        throwsA(isA<CgScriptException>()));
    expect(reads, 2);
    expect(posts, 4);
  });

  test(
      'debug caches the local session token across sequential and concurrent runs',
      () async {
    var sessionReads = 0;
    final transport = MockClient((request) async {
      expect(request.url.origin, 'http://localhost:5678');
      expect(request.headers.containsKey('Authorization'), isFalse);
      if (request.method == 'GET') {
        expect(request.url.path, '/api/configs');
        sessionReads++;
        return http.Response(
            jsonEncode({'devApiToken': 'local-$sessionReads'}), 200);
      }
      expect(request.headers['X-Cg-Token'], 'local-$sessionReads');
      expect(request.url.path, '/api/cgscript/run/Folder/A');
      expect(jsonDecode(request.body), {'id': 7});
      return http.Response('{"result":42}', 200);
    });
    addTearDown(transport.close);
    final client = CgScriptClient(
        debug: true,
        localServer: Uri.parse('http://localhost:5678'),
        client: transport);
    expect(await client.run('Folder/A', parameter: {'id': 7}), 42);
    expect(await client.run('Folder/A', parameter: {'id': 7}), 42);
    expect(
        await Future.wait(List.generate(
            3, (_) => client.run('Folder/A', parameter: {'id': 7}))),
        everyElement(42));
    expect(sessionReads, 1);
  });

  test('an explicit empty provider does not fall back to server authentication',
      () async {
    final transport = MockClient((_) async => fail('No request expected'));
    addTearDown(transport.close);
    final client =
        CgScriptClient(debug: true, accessToken: () => null, client: transport);
    await expectLater(client.run('A', parameter: null), throwsStateError);
  });

  test('debug paths and deployed IDs share JSON parameters and decoded results',
      () async {
    final requests = <http.Request>[];
    final transport = MockClient((request) async {
      requests.add(request);
      return http.Response('{"result":{"value":42},"error":null}', 200);
    });
    addTearDown(transport.close);
    for (final debug in [true, false]) {
      final client = CgScriptClient(
          debug: debug,
          issuer: Uri.parse('https://site.test/dashboard/7'),
          workflowIds: {'Folder/A': 123},
          client: transport,
          accessToken: () async => 'token');
      expect(await client.run('Folder/A', parameter: {'id': 7}), {'value': 42});
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
    final client = CgScriptClient(
        debug: false,
        issuer: Uri.parse('https://site.test/'),
        workflowIds: {'A': 1},
        client: transport);
    expect(await client.run('A', parameter: [1, 2], expandParameters: true),
        isNull);
    await expectLater(client.run('Missing', parameter: {}), throwsStateError);
  });

  test('both environments preserve Catglobe script errors', () async {
    final transport = MockClient((_) async =>
        http.Response('{"result":null,"error":{"message":"failed"}}', 200));
    addTearDown(transport.close);
    for (final debug in [true, false]) {
      final client = CgScriptClient(
          debug: debug,
          issuer: Uri.parse('https://site.test/'),
          workflowIds: {'A': 1},
          accessToken: () => 'token',
          client: transport);
      await expectLater(
          client.run('A', parameter: null), throwsA(isA<CgScriptException>()));
    }
  });
}
