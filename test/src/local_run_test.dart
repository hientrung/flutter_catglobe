import 'dart:convert';
import 'dart:io';
import 'package:catglobe/catglobe.dart';
import 'package:catglobe/catglobe_client.dart';
import 'package:catglobe/src/script_rewriter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('local expansion escapes nested source and supports shared dependencies',
      () {
    final sources = {
      'A':
          'return {new WorkflowScript("B").Call(), new WorkflowScript("C").Call()};',
      'B': 'return new WorkflowScript("C").Call();',
      'C': 'return "quote\\\" and newline\\n";',
    };
    final local =
        ScriptRewriter(mode: ScriptRewriteMode.local, sources: sources)
            .rewrite('A');
    expect(local, contains('${jsonEncode(sources['C'])}, false'));
    expect(local, isNot(contains('new WorkflowScript("B")')));
    final deploy = ScriptRewriter(
        mode: ScriptRewriteMode.deploy,
        sources: sources,
        ids: {'B': 12, 'C': 13}).rewrite('A');
    expect(deploy,
        'return {new WorkflowScript(12).Call(), new WorkflowScript(13).Call()};');
  });

  test('local detects cycles but deployment allows numeric cyclic references',
      () {
    final sources = {
      'A': 'new WorkflowScript("B");',
      'B': 'new WorkflowScript("A");'
    };
    expect(
        () => ScriptRewriter(mode: ScriptRewriteMode.local, sources: sources)
            .rewrite('A'),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'path', contains('A -> B -> A'))));
    expect(
        ScriptRewriter(
            mode: ScriptRewriteMode.deploy,
            sources: sources,
            ids: {'A': 1, 'B': 2}).rewrite('A'),
        'new WorkflowScript(2);');
    expect(
        () => ScriptRewriter(
            mode: ScriptRewriteMode.local,
            sources: {'A': sources['A']!}).rewrite('A'),
        throwsFormatException);
  });

  test(
      'local API loads latest files, forwards parameters, and rejects unsafe requests',
      () async {
    final temp = await Directory.systemTemp.createTemp('cg-local-run-');
    final scripts = Directory(p.join(temp.path, 'cgscript'));
    await scripts.create();
    final a = File(p.join(scripts.path, 'A.cgs'));
    final b = File(p.join(scripts.path, 'B@123.public.cgs'));
    await a.writeAsString('return new WorkflowScript("B").Call();');
    await b.writeAsString('return 42;');
    final calls = <Map<String, dynamic>>[];
    final server =
        DevelopmentServer(ConfigStore(File(p.join(temp.path, 'configs.json'))),
            client: MockClient((request) async {
      expect(request.url.path, '/api/cgscript/dynamicrun');
      expect(request.headers['Authorization'], 'Bearer remote-token');
      calls.add(jsonDecode(request.body) as Map<String, dynamic>);
      if (calls.last['Parameter'] is Map &&
          calls.last['Parameter']['reject'] == true) {
        return http.Response(
            '{"result":null,"error":{"message":"expired"}}', 401);
      }
      if (request.url.queryParameters['expandParameters'] == 'true') {
        expect(calls.last['Parameter'], [1, 2]);
      }
      return http.Response('{"result":{"value":42}}', 200);
    }));
    await server.start(port: 0);
    final client = http.Client();
    addTearDown(() async {
      client.close();
      await server.close();
      await temp.delete(recursive: true);
    });
    final state =
        jsonDecode((await client.get(server.url.resolve('/api/configs'))).body)
            as Map;
    final token = state['devApiToken'] as String;
    final headers = {'Content-Type': 'application/json', 'X-Cg-Token': token};
    await client.post(server.url.resolve('/api/configs'),
        headers: headers,
        body: jsonEncode({
          'id': 'one',
          'name': 'one',
          'issuer': 'https://site.test/',
          'projectPath': temp.path,
        }));
    await client.post(server.url.resolve('/api/select'),
        headers: headers, body: '{"id":"one"}');
    server.auth.accessToken = 'console-token-must-not-be-used';
    server.auth.configId = 'one';
    server.auth.expiresAt = DateTime.now().add(Duration(minutes: 5));
    final runHeaders = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer remote-token'
    };
    final endpoint = server.url.resolve('/api/cgscript/run/A');
    final response = await client.post(endpoint,
        headers: {...runHeaders, 'Origin': 'http://localhost:8080'},
        body: '{"id":7,"items":[true,null]}');
    expect(response.statusCode, 200);
    expect(jsonDecode(response.body), {
      'result': {'value': 42}
    });
    expect(response.headers['access-control-allow-origin'],
        'http://localhost:8080');
    expect(calls.single['Parameter'], {
      'id': 7,
      'items': [true, null]
    });
    expect(calls.single['ScriptName'], 'A');
    expect(calls.single['Script'],
        'return new WorkflowScript("return 42;", false).Call();');
    final preflight = await client.send(http.Request('OPTIONS', endpoint)
      ..headers['Origin'] = 'http://localhost:8080');
    expect(preflight.statusCode, 204);
    await preflight.stream.drain<void>();
    expect((await client.post(endpoint, body: '{}')).statusCode, 403);
    expect(
        (await client.post(endpoint,
                headers: {...runHeaders, 'Origin': 'https://evil.test'},
                body: '{}'))
            .statusCode,
        403);
    await b.writeAsString('return 99;');
    await client.post(endpoint, headers: runHeaders, body: 'null');
    expect(calls.last['Script'], contains('return 99;'));
    expect(calls.last['Parameter'], isNull);
    await b.writeAsString('return new WorkflowScript("A").Call();');
    final cycle = await client.post(endpoint, headers: runHeaders, body: '{}');
    expect(cycle.statusCode, 400);
    expect(cycle.body, contains('A -> B -> A'));
    expect(calls.length, 2);
    final missing = await client.post(
        server.url.resolve('/api/cgscript/run/Missing'),
        headers: runHeaders,
        body: '{}');
    expect(missing.statusCode, 400);
    expect(calls.length, 2);
    server.auth.accessToken = 'remote-token';
    await b.writeAsString('return 88;');
    final textarea = await client.post(server.url.resolve('/api/run'),
        headers: headers,
        body: jsonEncode({'script': 'return new WorkflowScript("B").Call();'}));
    expect(textarea.statusCode, 200);
    expect(calls.last['Script'],
        'return new WorkflowScript("return 88;", false).Call();');
    expect(calls.last['Parameter'], isEmpty);
    await b.writeAsString('return new WorkflowScript("A").Call();');
    final textareaCycle = await client.post(server.url.resolve('/api/run'),
        headers: headers,
        body: jsonEncode({'script': 'return new WorkflowScript("B").Call();'}));
    expect(textareaCycle.statusCode, 400);
    expect(textareaCycle.body, contains('Circular workflow reference'));
    expect(calls.length, 3);
    await b.writeAsString('return true;');
    final denied = await client.post(endpoint,
        headers: runHeaders, body: '{"reject":true}');
    expect(denied.statusCode, 401);
    expect(jsonDecode(denied.body), {
      'result': null,
      'error': {'message': 'expired'}
    });
    final expanded = await client.post(
        endpoint.replace(queryParameters: {'expandParameters': 'true'}),
        headers: runHeaders,
        body: '[1,2]');
    expect(expanded.statusCode, 200);

    final browserTransport = MockClient((request) async {
      final forwarded = http.Request(request.method, request.url)
        ..headers.addAll(request.headers)
        ..headers['Origin'] = 'http://localhost:8080'
        ..bodyBytes = request.bodyBytes;
      final response = await client.send(forwarded);
      expect(response.headers['access-control-allow-origin'],
          'http://localhost:8080');
      return http.Response.fromStream(response);
    });
    addTearDown(browserTransport.close);
    final workflows = CatglobeWorkflowClient(
        debug: true, localServer: server.url, client: browserTransport);
    expect(await workflows.run('A', parameter: [1, 2], expandParameters: true),
        {'value': 42});
    final sessionPreflight = await client.send(http.Request('OPTIONS', endpoint)
      ..headers['Origin'] = 'http://localhost:8080'
      ..headers['Access-Control-Request-Headers'] = 'x-cg-token');
    expect(sessionPreflight.headers['access-control-allow-headers'],
        contains('X-Cg-Token'));
    await sessionPreflight.stream.drain<void>();
    expect(
        (await client.get(server.url.resolve('/api/configs'),
                headers: {'Origin': 'https://evil.test'}))
            .statusCode,
        403);
    expect(
        (await client.post(endpoint,
                headers: {'X-Cg-Token': 'wrong'}, body: 'null'))
            .statusCode,
        403);
    server.auth.clear();
    await expectLater(
        workflows.run('A', parameter: null), throwsA(isA<CgScriptException>()));
  });
}
