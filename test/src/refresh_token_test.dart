import 'dart:async';
import 'dart:convert';
import 'package:catglobe_dev/src/auth.dart';
import 'package:catglobe_dev/src/config.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

Future<void> login(Authentication auth) async {
  final config = ProjectConfig({
    'id': 'one',
    'name': 'one',
    'projectPath': '.',
    'issuer': 'https://site.test/',
    'clientId': 'public'
  });
  final uri = await auth.begin(config, 'http://localhost:5000/auth/callback');
  await auth.complete(Uri(queryParameters: {
    'state': uri.queryParameters['state']!,
    'code': 'code'
  }));
}

http.Response initialResponse(http.Request request) {
  if (request.url.path.endsWith('openid-configuration')) {
    return http.Response(
        jsonEncode({
          'issuer': 'https://site.test/',
          'authorization_endpoint': 'https://site.test/auth',
          'token_endpoint': 'https://site.test/token',
          'code_challenge_methods_supported': ['S256']
        }),
        200);
  }
  return http.Response(
      jsonEncode({
        'token_type': 'Bearer',
        'access_token': 'old',
        'expires_in': 3600,
        'refresh_token': 'refresh-one'
      }),
      200);
}

void main() {
  test(
      'refreshes on expiry, shares concurrent refresh and keeps rotated tokens',
      () async {
    final gate = Completer<void>();
    final received = <String>[];
    final auth = Authentication(MockClient((request) async {
      final body = request.url.path == '/token'
          ? Uri.splitQueryString(request.body)
          : <String, String>{};
      if (body['grant_type'] != 'refresh_token')
        return initialResponse(request);
      received.add(body['refresh_token']!);
      expect(body['client_id'], 'public');
      expect(body.containsKey('client_secret'), isFalse);
      if (received.length == 1) await gate.future;
      return http.Response(
          jsonEncode({
            'token_type': 'Bearer',
            'access_token': 'new-${received.length}',
            'expires_in': 3600,
            if (received.length == 1) 'refresh_token': 'refresh-two'
          }),
          200);
    }));
    addTearDown(auth.client.close);
    await login(auth);
    expect(await auth.validAccessToken('one'), 'old');
    auth.expiresAt = DateTime.now().subtract(Duration(seconds: 1));
    final first = auth.validAccessToken('one');
    final second = auth.validAccessToken('one');
    gate.complete();
    expect(await Future.wait([first, second]), ['new-1', 'new-1']);
    expect(received, ['refresh-one']);
    for (var i = 0; i < 2; i++) {
      auth.expiresAt = DateTime.now();
      await auth.validAccessToken('one');
    }
    expect(received, ['refresh-one', 'refresh-two', 'refresh-two']);
  });

  test('invalid_grant clears the session and requires login', () async {
    final auth = Authentication(MockClient((request) async {
      if (request.body.contains('grant_type=refresh_token'))
        return http.Response('{"error":"invalid_grant"}', 400);
      return initialResponse(request);
    }));
    addTearDown(auth.client.close);
    await login(auth);
    auth.expiresAt = DateTime.now();
    await expectLater(auth.validAccessToken('one'), throwsStateError);
    expect(auth.accessToken, isNull);
    expect(auth.configId, isNull);
  });

  test('logout during refresh cannot restore a cleared session', () async {
    final started = Completer<void>();
    final gate = Completer<void>();
    final auth = Authentication(MockClient((request) async {
      if (request.body.contains('grant_type=refresh_token')) {
        started.complete();
        await gate.future;
        return http.Response(
            '{"token_type":"Bearer","access_token":"new","expires_in":3600}',
            200);
      }
      return initialResponse(request);
    }));
    addTearDown(auth.client.close);
    await login(auth);
    auth.expiresAt = DateTime.now();
    final refresh = auth.validAccessToken('one');
    final check = expectLater(refresh, throwsStateError);
    await started.future;
    auth.clear();
    gate.complete();
    await check;
    expect(auth.accessToken, isNull);
  });
}
