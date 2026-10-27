import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'cgscript.dart';
import 'workflow_ids_stub.dart'
    if (dart.library.js_interop) 'workflow_ids_web.dart';

class CatglobeWorkflowClient {
  CatglobeWorkflowClient(
      {required this.debug,
      Uri? issuer,
      Uri? localServer,
      Map<String, int>? workflowIds,
      this.accessToken,
      http.Client? client})
      : issuer = issuer ?? Uri.base,
        localServer = localServer ?? Uri.parse('http://localhost:5000'),
        workflowIds = workflowIds ?? (debug ? const {} : readWorkflowIds()),
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  /// Pass Flutter's kDebugMode. This library has no Flutter SDK dependency.
  final bool debug;
  final Uri issuer;
  final Uri localServer;
  final Map<String, int> workflowIds;

  /// Obtain a current token from the Flutter app's authentication provider.
  /// May be omitted online to use same-origin browser authentication.
  final FutureOr<String?> Function()? accessToken;
  final http.Client _client;
  final bool _ownsClient;

  Future<Object?> run(String name, Object? parameter,
      {bool expandParameters = false}) async {
    if (name.isEmpty ||
        name.split('/').any((s) => s.isEmpty || s == '.' || s == '..') ||
        name.contains('\\')) {
      throw ArgumentError.value(
          name, 'name', 'Expected a workflow path without filename metadata');
    }
    final String target;
    if (debug) {
      target = name;
    } else {
      final id = workflowIds[name];
      if (id == null || id <= 0)
        throw StateError('Missing deployed Workflow ID for $name');
      target = '$id';
    }
    final base = debug ? localServer : issuer;
    if (!base.hasAuthority || !['http', 'https'].contains(base.scheme))
      throw ArgumentError('Expected an HTTP(S) server URL');
    var endpoint = base.resolveUri(Uri(path: '/api/cgscript/run/$target'));
    if (expandParameters)
      endpoint =
          endpoint.replace(queryParameters: {'expandParameters': 'true'});
    final token = await accessToken?.call();
    if (debug && (token == null || token.isEmpty))
      throw StateError(
          'A Catglobe access token is required for local execution');
    final request = http.Request('POST', endpoint)
      ..followRedirects = false
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode(parameter);
    if (token != null && token.isNotEmpty)
      request.headers['Authorization'] = 'Bearer $token';
    final response =
        await _client.send(request).timeout(const Duration(seconds: 60));
    final body = await response.stream
        .bytesToString()
        .timeout(const Duration(seconds: 60));
    return parseCgScriptResponse(body, response.statusCode);
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
