import 'dart:convert';
import 'dart:io';
import 'package:catglobe_dev/catglobe_dev.dart';
import 'package:catglobe_dev/src/auth.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

ProjectConfig config(String name) => ProjectConfig({
      'id': name,
      'name': name,
      'projectPath': Directory.current.path,
      'issuer': 'https://example.com/',
      'clientId': 'public-client',
    });

void main() {
  test('stored redirect URI is discarded because callback follows runtime port',
      () {
    final project = ProjectConfig({
      ...config('one').data,
      'redirectUri': 'http://localhost:9999/auth/callback'
    });
    expect(project.toJson().containsKey('redirectUri'), isFalse);
  });
  test('PKCE matches RFC 7636 S256 example', () {
    expect(pkceChallenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
  });

  test('shared store preserves other projects and updates matching ID',
      () async {
    final temp = await Directory.systemTemp.createTemp('catglobe-test');
    addTearDown(() => temp.delete(recursive: true));
    final store = ConfigStore(File('${temp.path}/projects.json'));
    await store.save(config('one'));
    await store.save(config('two'));
    await store.save(ProjectConfig({...config('one').data, 'name': 'updated'}));
    final projects = await store.read();
    expect(projects.length, 2);
    expect(projects.firstWhere((c) => c.id == 'one').value('name'), 'updated');
  });

  test('PKCE callback binds state and exchanges verifier without secret',
      () async {
    var exchanges = 0;
    final auth = Authentication(MockClient((request) async {
      if (request.url.path.endsWith('openid-configuration')) {
        return http.Response(
            jsonEncode({
              'issuer': 'https://example.com/',
              'authorization_endpoint': 'https://example.com/authorize',
              'token_endpoint': 'https://example.com/token',
              'code_challenge_methods_supported': ['S256'],
            }),
            200);
      }
      exchanges++;
      final body = Uri.splitQueryString(request.body);
      expect(body['code_verifier'], isNotEmpty);
      expect(body.containsKey('client_secret'), isFalse);
      return http.Response(
          jsonEncode({
            'access_token': 'token',
            'token_type': 'Bearer',
            'expires_in': 300
          }),
          200);
    }));
    addTearDown(auth.client.close);
    final url =
        await auth.begin(config('one'), 'http://localhost:5000/auth/callback');
    expect(url.queryParameters['scope'],
        'email profile roles openid offline_access');
    await expectLater(
        auth.complete(Uri.parse('http://localhost/?state=wrong&code=x')),
        throwsStateError);
    expect(exchanges, 0);
    await auth.complete(Uri(queryParameters: {
      'state': url.queryParameters['state']!,
      'code': 'code'
    }));
    expect(auth.authenticated('one'), isTrue);
    expect(auth.authenticated('two'), isFalse);
    await expectLater(
        auth.complete(Uri(queryParameters: {
          'state': url.queryParameters['state']!,
          'code': 'code'
        })),
        throwsStateError);
  });

  test('local server starts with no selection and rejects untrusted mutations',
      () async {
    final temp = await Directory.systemTemp.createTemp('catglobe-server');
    final server =
        DevelopmentServer(ConfigStore(File('${temp.path}/projects.json')));
    await server.start(port: 0);
    expect(server.url.scheme, 'http');
    expect(server.url.host, 'localhost');
    expect(server.url.port, greaterThan(0));
    final client = http.Client();
    addTearDown(() async {
      client.close();
      await server.close();
      await temp.delete(recursive: true);
    });
    final page = await client.get(server.url);
    expect(page.statusCode, 200);
    expect(page.body, contains('Catglobe Developer Tools'));
    expect(page.body,
        contains('projectPath:${jsonEncode(Directory.current.path)}'));
    expect(page.body, isNot(contains('__PROJECT_PATH_JSON__')));
    final state =
        jsonDecode((await client.get(server.url.resolve('/api/configs'))).body)
            as Map;
    expect(state['selected'], isNull);
    expect(state['projects'], isEmpty);
    final rejected =
        await client.post(server.url.resolve('/api/configs'), body: '{}');
    expect(rejected.statusCode, 403);
    final token =
        RegExp("const token='([^']+)'").firstMatch(page.body)!.group(1)!;
    Future<http.Response> post(String route, Object body) =>
        client.post(server.url.resolve('/api/$route'),
            headers: {'X-Cg-Token': token, 'Content-Type': 'application/json'},
            body: jsonEncode(body));
    expect((await post('configs', config('one').data)).statusCode, 200);
    expect((await post('select', {'id': 'one'})).statusCode, 200);
    final emptyScript = await post('run', {'script': '   '});
    expect(emptyScript.statusCode, 400);
    expect(emptyScript.body, contains('Enter a CGScript to run'));
    final fileRequest = await post('run', {'file': 'example.cgscript'});
    expect(fileRequest.statusCode, 400);
    expect(fileRequest.body, contains('Enter a CGScript to run'));
    final invalidMode =
        await post('deploy', {'kind': 'build', 'mode': 'other'});
    expect(invalidMode.statusCode, 400);
    expect(invalidMode.body, contains('mode must be test or production'));
    expect((await post('configs', config('two').data)).statusCode, 200);
    expect((await post('select', {'id': ''})).statusCode, 200);
    var current =
        jsonDecode((await client.get(server.url.resolve('/api/configs'))).body)
            as Map;
    expect(current['selected'], isNull);
    expect((await post('select', {'id': 'one'})).statusCode, 200);
    server.auth.accessToken = 'test-token';
    server.auth.configId = 'one';
    server.auth.expiresAt = DateTime.now().add(const Duration(minutes: 1));
    expect((await post('delete', {'id': 'one'})).statusCode, 200);
    current =
        jsonDecode((await client.get(server.url.resolve('/api/configs'))).body)
            as Map;
    expect(current['selected'], isNull);
    expect(current['authenticated'], isFalse);
    expect((current['projects'] as List).map((c) => c['id']), ['two']);
    expect((await post('delete', {'id': 'missing'})).statusCode, 400);
  });
}
