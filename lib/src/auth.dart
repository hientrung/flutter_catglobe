import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'config.dart';

/// Generates a cryptographically random, unpadded Base64URL secret.
String randomSecret() =>
    base64UrlEncode(List<int>.generate(32, (_) => Random.secure().nextInt(256)))
        .replaceAll('=', '');

/// Returns the S256 PKCE challenge for the ASCII [verifier].
String pkceChallenge(String verifier) =>
    base64UrlEncode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');

/// The state and PKCE verifier for a pending authorization-code exchange.
class LoginAttempt {
  /// Creates a login attempt for [config] using discovered [metadata].
  LoginAttempt(this.config, this.metadata, this.redirect);

  /// The project for which authorization is requested.
  final ProjectConfig config;

  /// The discovery metadata used for this authorization attempt.
  final Map<String, dynamic> metadata;

  /// The callback URL sent in authorization and token requests.
  final String redirect;

  /// The random value used to bind the callback to this attempt.
  final String state = randomSecret();

  /// The random PKCE verifier used during code exchange.
  final String verifier = randomSecret();

  /// The creation time used to enforce the five-minute callback lifetime.
  final DateTime created = DateTime.now();
}

/// Manages an in-memory authorization-code session with S256 PKCE.
///
/// Requests `openid offline_access` and keeps access and refresh tokens only
/// in memory. ID tokens are not validated or used as identity assertions.
/// Call [validAccessToken] before authenticated API operations.
class Authentication {
  /// Creates a session using the caller-owned HTTP [client].
  Authentication(this.client);

  /// The HTTP transport used for discovery, code exchange, and token refresh.
  final http.Client client;

  /// The authorization attempt awaiting a callback, or `null`.
  LoginAttempt? pending;

  /// The current Bearer token, which may require renewal before use.
  String? accessToken;

  /// The project identifier associated with the current session.
  String? configId;

  /// The expiry time reported for the current access token.
  DateTime? expiresAt;
  String? _refreshToken;
  String? _clientId;
  Uri? _tokenEndpoint;
  Future<String>? _refreshing;
  int _generation = 0;

  /// Reports whether [id] has a currently unexpired access token.
  ///
  /// Does not attempt refresh; use [validAccessToken] before API requests.
  bool authenticated(String id) =>
      configId == id &&
      accessToken != null &&
      expiresAt != null &&
      DateTime.now().isBefore(expiresAt!);

  /// Clears pending login and token state, invalidating ongoing refresh results.
  void clear() {
    _generation++;
    _refreshing = null;
    _refreshToken = null;
    _clientId = null;
    _tokenEndpoint = null;
    pending = null;
    accessToken = null;
    configId = null;
    expiresAt = null;
  }

  /// Starts login for [config] and returns the browser authorization URL.
  ///
  /// Clears the existing session, discovers issuer endpoints, and requests
  /// `openid offline_access` with [redirect] as the callback URL.
  /// Throws [StateError] for missing client settings or incompatible discovery
  /// metadata. Network and JSON decoding errors propagate.
  Future<Uri> begin(ProjectConfig config, String redirect) async {
    clear();
    if (config.value('clientId').isEmpty)
      throw StateError('Configure clientId first');
    final issuer = Uri.parse(config.value('issuer'));
    final discovery = issuer.resolve('.well-known/openid-configuration');
    final response =
        await client.get(discovery).timeout(const Duration(seconds: 30));
    if (response.statusCode != 200)
      throw StateError('Discovery failed (${response.statusCode})');
    final metadata = jsonDecode(response.body) as Map<String, dynamic>;
    if (metadata['issuer'] != issuer.toString())
      throw StateError(
          'Discovery issuer mismatch; use the exact issuer including trailing slash');
    if (!(metadata['code_challenge_methods_supported'] as List? ?? [])
        .contains('S256')) {
      throw StateError('Provider does not advertise PKCE S256');
    }
    for (final key in ['authorization_endpoint', 'token_endpoint']) {
      final endpoint = Uri.parse(metadata[key] as String);
      if (endpoint.scheme != 'https' || endpoint.host.isEmpty)
        throw StateError('Invalid $key');
    }
    final attempt = LoginAttempt(config, metadata, redirect);
    pending = attempt;
    return Uri.parse(metadata['authorization_endpoint'] as String)
        .replace(queryParameters: {
      'client_id': config.value('clientId'),
      'redirect_uri': redirect,
      'response_type': 'code',
      'scope': 'openid offline_access',
      'state': attempt.state,
      'code_challenge': pkceChallenge(attempt.verifier),
      'code_challenge_method': 'S256',
    });
  }

  /// Validates [callback] and exchanges its code for in-memory tokens.
  ///
  /// Consumes the pending attempt and checks state, lifetime, and any returned
  /// issuer. Throws [StateError] for rejected or invalid callbacks and token
  /// responses. Does not validate ID tokens or establish an asserted user identity.
  Future<void> complete(Uri callback) async {
    final attempt = pending;
    if (attempt == null ||
        callback.queryParameters['state'] != attempt.state ||
        DateTime.now().difference(attempt.created) >
            const Duration(minutes: 5)) {
      throw StateError('Invalid or expired login state');
    }
    pending = null;
    final responseIssuer = callback.queryParameters['iss'];
    if (responseIssuer != null &&
        responseIssuer != attempt.metadata['issuer']) {
      throw StateError('Authorization issuer mismatch');
    }
    if (callback.queryParameters.containsKey('error'))
      throw StateError('Login rejected');
    final code = callback.queryParameters['code'];
    if (code == null || code.isEmpty)
      throw StateError('Missing authorization code');
    final response = await client
        .post(Uri.parse(attempt.metadata['token_endpoint'] as String), body: {
      'grant_type': 'authorization_code',
      'client_id': attempt.config.value('clientId'),
      'redirect_uri': attempt.redirect,
      'code': code,
      'code_verifier': attempt.verifier,
    }).timeout(const Duration(seconds: 30));
    if (response.statusCode != 200)
      throw StateError(
          'Token exchange failed (${response.statusCode}); verify public client settings');
    final token = jsonDecode(response.body) as Map<String, dynamic>;
    _applyToken(token);
    _clientId = attempt.config.value('clientId');
    _tokenEndpoint = Uri.parse(attempt.metadata['token_endpoint'] as String);
    configId = attempt.config.id;
    // ID tokens are deliberately not used as identity assertions.
  }

  void _applyToken(Map<String, dynamic> token) {
    if (token['token_type']?.toString().toLowerCase() != 'bearer' ||
        token['access_token'] is! String ||
        (token['access_token'] as String).isEmpty ||
        token['expires_in'] is! num ||
        (token['expires_in'] as num) <= 0 ||
        (token.containsKey('refresh_token') &&
            (token['refresh_token'] is! String ||
                (token['refresh_token'] as String).isEmpty))) {
      throw StateError('Unsupported token response');
    }
    accessToken = token['access_token'] as String;
    expiresAt = DateTime.now()
        .add(Duration(seconds: (token['expires_in'] as num).toInt()));
    if (token['refresh_token'] is String)
      _refreshToken = token['refresh_token'] as String;
  }

  /// Returns a current access token for project [id], refreshing if necessary.
  ///
  /// When refresh is available, renews tokens expiring within 30 seconds.
  /// Concurrent callers share the pending refresh. Throws [StateError] if
  /// login is required, refresh fails, or the session changes during refresh.
  Future<String> validAccessToken(String id) async {
    if (configId != id) throw StateError('Login required');
    final canRefresh =
        _refreshToken != null && _tokenEndpoint != null && _clientId != null;
    if (authenticated(id) &&
        (!canRefresh ||
            expiresAt!
                .isAfter(DateTime.now().add(const Duration(seconds: 30))))) {
      return accessToken!;
    }
    if (!canRefresh) throw StateError('Login required or session expired');
    final pending = _refreshing;
    if (pending != null) return pending;
    final future = _refresh(_generation);
    _refreshing = future;
    try {
      return await future;
    } finally {
      if (identical(_refreshing, future)) _refreshing = null;
    }
  }

  Future<String> _refresh(int generation) async {
    final response = await client.post(_tokenEndpoint!, body: {
      'grant_type': 'refresh_token',
      'client_id': _clientId!,
      'refresh_token': _refreshToken!,
    }).timeout(const Duration(seconds: 30));
    if (generation != _generation)
      throw StateError('Login session changed during refresh');
    final token = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      if (token['error'] == 'invalid_grant' ||
          token['error'] == 'invalid_client') clear();
      throw StateError(
          'Unable to refresh access token (${response.statusCode}); log in again if the session was revoked');
    }
    _applyToken(token);
    return accessToken!;
  }
}
