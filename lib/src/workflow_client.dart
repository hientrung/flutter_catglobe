import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'cgscript.dart';
import 'workflow_ids_stub.dart'
    if (dart.library.js_interop) 'workflow_ids_web.dart';

/// Runs named Catglobe workflows locally in debug and by deployed ID online.
///
/// In debug, workflow names resolve to source files in the local server's
/// selected project. Without [accessToken], execution uses that project's
/// current server login session; select a project and log in through the local
/// management console first. The Catglobe access token stays on the server.
/// The development API token is loaded once per client and shared by concurrent
/// calls. If the local server rejects it after a restart, it is reloaded and the
/// rejected request is retried once.
///
/// Outside debug, names resolve through [workflowIds] and requests go to [issuer].
/// Authentication uses [accessToken] when supplied, or the browser's same-origin
/// login session when available.
///
/// Flutter usage (this library itself has no Flutter SDK dependency):
///
/// ```dart
/// import 'package:flutter/foundation.dart';
/// import 'package:catglobe/catglobe_client.dart';
///
/// final workflows = CatglobeWorkflowClient(debug: kDebugMode);
/// try {
///   final result = await workflows.run('Folder/Name', parameter: {'customerId': 123});
///   print(result);
/// } on CgScriptException catch (error) {
///   print(error.error);
/// } finally {
///   workflows.close();
/// }
/// ```
class CatglobeWorkflowClient {
  /// Creates a workflow client with optional server and authentication settings.
  ///
  /// Pass Flutter's `kDebugMode` as [debug]. The default [issuer] is [Uri.base]
  /// and the default [localServer] is `http://localhost:5000`. If [workflowIds]
  /// is omitted outside debug, reads `globalThis.catglobeWorkflowIds` injected
  /// into the deployed web Dashboard.
  ///
  /// If [client] is supplied, its caller owns it and must close it separately.
  /// Otherwise, [close] releases the HTTP client created by this instance.
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

  /// Whether workflows execute through the local development server.
  ///
  /// Pass Flutter's `kDebugMode` to follow the app's build mode.
  final bool debug;

  /// The HTTP(S) server URL used for deployed workflow execution.
  final Uri issuer;

  /// The HTTP(S) development server URL used when [debug] is `true`.
  final Uri localServer;

  /// The mapping from workflow names to positive deployed resource IDs.
  ///
  /// Used outside debug; a missing or invalid ID causes [run] to fail.
  final Map<String, int> workflowIds;

  /// The provider of a current token from the Flutter app's authentication.
  ///
  /// When omitted in debug, uses the local server's current login session.
  /// May be omitted online to use same-origin browser authentication.
  /// The callback is invoked for each [run] and is responsible for token renewal.
  /// A supplied callback returning `null` or an empty string in debug causes
  /// an error instead of falling back to the server's session.
  final FutureOr<String?> Function()? accessToken;
  final http.Client _client;
  final bool _ownsClient;
  Future<String>? _localToken;

  /// Executes [name] with JSON-encodable [parameter] and returns its result.
  ///
  /// Use a path relative to the script directory, such as `Folder/Name`, without
  /// `.cgs`, `@userId`, or `.public` filename metadata. In debug, the local server
  /// reloads source files on each call. Online, [workflowIds] supplies the ID.
  ///
  /// Omitted or null [parameter] is sent as an empty JSON array.
  /// By default, the script receives [parameter] as one argument at
  /// `Workflow_getParameters()[0]`. Set [expandParameters] to `true` and supply
  /// a JSON array to pass its elements as positional arguments instead.
  ///
  /// Returns the decoded `result`, including `null`. Throws [CgScriptException]
  /// for a non-null Catglobe `error`, including errors returned with HTTP 200.
  /// Invalid names or server URLs throw [ArgumentError]; missing deployed IDs
  /// or unavailable local authentication throw [StateError]. Transport, timeout,
  /// and response decoding errors propagate to the caller.
  Future<Object?> run(String name,
      {Object? parameter, bool expandParameters = false}) async {
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
    String? devToken;
    if (debug && accessToken == null) {
      devToken = await _getLocalToken();
    } else if (debug && (token == null || token.isEmpty)) {
      throw StateError(
          'A Catglobe access token is required for local execution');
    }
    for (var attempt = 0;; attempt++) {
      final request = http.Request('POST', endpoint)
        ..followRedirects = false
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode(parameter ?? const []);
      if (token != null && token.isNotEmpty)
        request.headers['Authorization'] = 'Bearer $token';
      if (devToken != null) request.headers['X-Cg-Token'] = devToken;
      final response =
          await _client.send(request).timeout(const Duration(seconds: 60));
      final body = await response.stream
          .bytesToString()
          .timeout(const Duration(seconds: 60));
      if (devToken != null &&
          attempt == 0 &&
          response.statusCode == 403 &&
          body == jsonEncode({'error': 'Request forbidden'})) {
        _localToken = null;
        devToken = await _getLocalToken();
        continue;
      }
      return parseCgScriptResponse(body, response.statusCode);
    }
  }

  Future<String> _getLocalToken() => _localToken ??= _loadLocalToken();

  Future<String> _loadLocalToken() async {
    try {
      final stateRequest =
          http.Request('GET', localServer.resolve('/api/configs'))
            ..followRedirects = false;
      final stateResponse =
          await _client.send(stateRequest).timeout(const Duration(seconds: 60));
      final stateBody = await stateResponse.stream
          .bytesToString()
          .timeout(const Duration(seconds: 60));
      if (stateResponse.statusCode != 200)
        throw StateError(
            'Cannot read local server session (${stateResponse.statusCode})');
      final state = jsonDecode(stateBody) as Map<String, dynamic>;
      final devToken = state['devApiToken'] as String?;
      if (devToken == null || devToken.isEmpty)
        throw StateError(
            'Local server did not provide a development API token');
      return devToken;
    } catch (_) {
      _localToken = null;
      rethrow;
    }
  }

  /// Closes the HTTP client created by this instance.
  ///
  /// Call when the owning service is disposed. An HTTP client supplied to the
  /// constructor remains open and must be closed by its owner.
  void close() {
    if (_ownsClient) _client.close();
  }
}
