import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'auth.dart';
import 'config.dart';
import 'web.dart';

typedef DeploymentScriptBuilder = String Function(ProjectConfig config,
    String kind, String mode, List<Map<String, String>> files);

class DevelopmentServer {
  DevelopmentServer(this.store, {this.deploymentScriptBuilder})
      : auth = Authentication(http.Client());
  final ConfigStore store;
  final DeploymentScriptBuilder? deploymentScriptBuilder;
  final Authentication auth;
  HttpServer? _server;
  ProjectConfig? _selected;
  final String _csrf = randomSecret();
  bool _busy = false;
  Uri get url => Uri.parse('http://localhost:${_server!.port}');

  Future<void> start({int port = 5000}) async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server!.listen(_handle);
  }

  Future<void> close() async {
    await _server?.close(force: true);
    auth.client.close();
    auth.clear();
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers.set('Cache-Control', 'no-store');
    response.headers.set('X-Content-Type-Options', 'nosniff');
    response.headers.set('X-Frame-Options', 'DENY');
    try {
      if (request.headers.value('host') != url.authority) {
        response.statusCode = 403;
        return;
      }
      if (request.method == 'GET' && request.uri.path == '/') {
        response.headers.contentType = ContentType.html;
        String scriptJson(String value) => jsonEncode(value)
            .replaceAll('<', r'\u003c')
            .replaceAll('>', r'\u003e')
            .replaceAll('&', r'\u0026');
        response.write(webPage
            .replaceAll('__CSRF__', _csrf)
            .replaceAll(
                '__PROJECT_PATH_JSON__', scriptJson(Directory.current.path))
            .replaceAll('__PROJECT_NAME_JSON__',
                scriptJson(p.basename(Directory.current.path))));
        return;
      }
      if (request.method == 'GET' && request.uri.path == '/auth/callback') {
        await auth.complete(request.uri);
        response.redirect(url);
        return;
      }
      response.headers.contentType = ContentType.json;
      if (request.method == 'GET' && request.uri.path == '/api/configs') {
        response.write(jsonEncode({
          'projects': await store.read(),
          'selected': _selected?.id,
          'authenticated':
              _selected != null && auth.authenticated(_selected!.id)
        }));
        return;
      }
      if (request.method != 'POST' ||
          request.headers.value('x-cg-token') != _csrf ||
          (request.headers.value('origin') != null &&
              request.headers.value('origin') != url.toString())) {
        response.statusCode = 403;
        response.write(jsonEncode({'error': 'Request forbidden'}));
        return;
      }
      if (_busy) throw StateError('Another operation is in progress');
      _busy = true;
      try {
        final bytes = <int>[];
        await for (final chunk in request) {
          bytes.addAll(chunk);
          if (bytes.length > 1024 * 1024) throw StateError('Request too large');
        }
        final body = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        Object result = {'ok': true};
        switch (request.uri.path) {
          case '/api/configs':
            final config = ProjectConfig(body);
            await store.save(config);
            if (_selected?.id == config.id) {
              _selected = config;
              auth.clear();
            }
          case '/api/delete':
            final id = body['id'];
            if (id is! String || id.isEmpty)
              throw const FormatException('Configuration ID is required');
            await store.delete(id);
            if (_selected?.id == id) {
              _selected = null;
              auth.clear();
            }
          case '/api/select':
            final id = body['id'];
            final selected = id == ''
                ? null
                : (await store.read()).firstWhere((c) => c.id == id);
            if (_selected?.id != selected?.id) auth.clear();
            _selected = selected;
          case '/api/login':
            final config = _requireSelected();
            final redirect = url.resolve('/auth/callback').toString();
            result = {'url': (await auth.begin(config, redirect)).toString()};
          case '/api/logout':
            auth.clear();
          case '/api/run':
            final config = _requireSelected();
            final script = body['script'];
            if (script is! String || script.trim().isEmpty) {
              throw const FormatException('Enter a CGScript to run');
            }
            result = await _runScript(config, script);
          case '/api/deploy':
            final config = _requireSelected();
            final kind = body['kind'];
            if (kind != 'scripts' && kind != 'build')
              throw StateError('Invalid deployment kind');
            final mode = body['mode'];
            if (mode != 'test' && mode != 'production') {
              throw const FormatException(
                  'Deployment mode must be test or production');
            }
            final builder = deploymentScriptBuilder;
            if (builder == null) {
              throw StateError(
                  'Deployment requires the Catglobe upload/write CGScript implementation');
            }
            final directory = await _localDirectory(
                config,
                config.value(
                    kind == 'scripts' ? 'scriptDirectory' : 'buildDirectory'));
            final files = <Map<String, String>>[];
            var size = 0;
            await for (final entity
                in directory.list(recursive: true, followLinks: false)) {
              if (entity is! File) continue;
              final bytes = await entity.readAsBytes();
              size += bytes.length;
              if (size > 50 * 1024 * 1024)
                throw StateError('Deployment exceeds 50 MiB');
              files.add({
                'path': p
                    .relative(entity.path, from: directory.path)
                    .split(p.separator)
                    .join('/'),
                'contentBase64': base64Encode(bytes)
              });
            }
            if (files.isEmpty) throw StateError('No deployment files found');
            final script =
                builder(config, kind as String, mode as String, files);
            if (script.trim().isEmpty)
              throw StateError('Deployment script is empty');
            result = await _runScript(config, script);
          default:
            response.statusCode = 404;
            result = {'error': 'Unknown route'};
        }
        response.write(jsonEncode(result));
      } finally {
        _busy = false;
      }
    } catch (error) {
      response.statusCode = 400;
      response.write(jsonEncode({'error': error.toString()}));
    } finally {
      await response.close();
    }
  }

  ProjectConfig _requireSelected() =>
      _selected ?? (throw StateError('Select a config first'));

  Future<Directory> _localDirectory(
      ProjectConfig config, String relative) async {
    if (relative.isEmpty || p.isAbsolute(relative))
      throw StateError('Directory must be relative to project');
    final root =
        await Directory(config.value('projectPath')).resolveSymbolicLinks();
    final directory =
        await Directory(p.join(root, relative)).resolveSymbolicLinks();
    if (!p.isWithin(root, directory))
      throw StateError('Directory escapes project');
    return Directory(directory);
  }

  Future<Object> _runScript(ProjectConfig config, String script) async {
    if (!auth.authenticated(config.id))
      throw StateError('Login required or session expired');
    final issuer = Uri.parse(config.value('issuer'));
    final endpoint = issuer.resolve('/api/cgscript/dynamicrun');
    if (endpoint.scheme != 'https' || endpoint.origin != issuer.origin) {
      throw StateError('API endpoint must use the issuer HTTPS origin');
    }
    final request = http.Request('POST', endpoint)
      ..followRedirects = false
      ..headers.addAll({
        'Authorization': 'Bearer ${auth.accessToken}',
        'Content-Type': 'application/json'
      })
      ..body = jsonEncode({
        'ScriptName': 'FlutterApp',
        'Script': script,
        'Parameter': <Object>[],
      });
    final response =
        await auth.client.send(request).timeout(const Duration(seconds: 60));
    final content = await response.stream
        .bytesToString()
        .timeout(const Duration(seconds: 60));
    return {
      'success': response.statusCode >= 200 && response.statusCode < 300,
      'status': response.statusCode,
      'body': content
    };
  }
}
