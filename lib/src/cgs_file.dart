import 'dart:convert';
import 'dart:async';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// Uploads permanent files using Catglobe's raw-stream Files API.
class CgsFileUploader {
  /// Creates an uploader using [client], [issuer], and a current-token provider.
  ///
  /// Throws [ArgumentError] unless [issuer] is an HTTPS URL. The caller owns
  /// [client] and must close it when no longer needed.
  CgsFileUploader(this.client, this.issuer, {required this.accessToken}) {
    if (issuer.scheme != 'https' || issuer.host.isEmpty) {
      throw ArgumentError.value(issuer, 'issuer', 'HTTPS origin required');
    }
  }

  /// The HTTP transport used for uploads.
  final http.Client client;

  /// The Catglobe HTTPS site receiving uploaded files.
  final Uri issuer;

  /// The provider called before each upload to obtain a current Bearer token.
  final FutureOr<String> Function() accessToken;

  /// The raw-stream Files API upload endpoint.
  Uri get endpoint => issuer.resolve('/api/files/upload/');

  /// Returns the Catglobe download URL for a stored file [name].
  Uri downloadUrl(String name) =>
      issuer.resolve('/CgScript/File').replace(queryParameters: {'file': name});

  /// Creates a deterministic Dashboard-specific filename for [relativePath].
  ///
  /// Hashes the normalized POSIX path and preserves its extension. Throws
  /// [ArgumentError] for invalid [dashboardId] and [FormatException] for unsafe
  /// paths or unsupported extensions.
  static String storageName(int dashboardId, String relativePath) {
    if (dashboardId <= 0) throw ArgumentError('Invalid Dashboard ID');
    if (relativePath.isEmpty ||
        p.posix.isAbsolute(relativePath) ||
        p.posix.normalize(relativePath) != relativePath ||
        p.posix
            .split(relativePath)
            .any((part) => part == '.' || part == '..') ||
        relativePath.contains('\\')) {
      throw FormatException('Invalid asset path: $relativePath');
    }
    final extension = p.posix.extension(relativePath);
    if (!RegExp(r'^\.[a-zA-Z0-9]+$').hasMatch(extension) &&
        extension.isNotEmpty) {
      throw FormatException('Unsupported asset extension: $relativePath');
    }
    // The server cleans path separators and invalid filename characters.
    // Hash the entire UTF-8 relative path to keep that operation collision-free.
    final hash = sha256.convert(utf8.encode(relativePath));
    return '${dashboardId}_$hash$extension';
  }

  /// Returns download URLs keyed by the original build-relative paths.
  /// The endpoint serves query URLs, not a directory usable as an HTML base.
  Future<Map<String, Uri>> upload(
      int dashboardId, Map<String, List<int>> files) async {
    // Validate all filenames before sending any part of the batch.
    final names = <String, String>{};
    for (final entry in files.entries) {
      names[entry.key] = storageName(dashboardId, entry.key);
    }
    final urls = <String, Uri>{};
    for (final entry in files.entries) {
      final token = await accessToken();
      if (token.isEmpty) throw StateError('Login required for file upload');
      final name = names[entry.key]!;
      final request = http.Request(
          'POST',
          endpoint.resolve(name).replace(
              queryParameters: {'overWrite': 'true', 'isTemp': 'false'}))
        ..followRedirects = false
        ..headers['Authorization'] = 'Bearer $token'
        ..headers['Content-Type'] = 'application/octet-stream'
        ..bodyBytes = entry.value;
      final response =
          await client.send(request).timeout(const Duration(seconds: 60));
      final body = await response.stream
          .bytesToString()
          .timeout(const Duration(seconds: 60));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
            'Upload failed for ${entry.key} (${response.statusCode})');
      }
      Object? result;
      try {
        result = jsonDecode(body);
      } on FormatException {
        throw FormatException(
            'Non-JSON upload response for ${entry.key}; verify the site accepts the access token');
      }
      if (result is! Map ||
          result['success'] != true ||
          result['filename'] != name ||
          result['isTemp'] != false ||
          result['size'] != entry.value.length) {
        throw StateError('Upload was not confirmed for ${entry.key}');
      }
      urls[entry.key] = downloadUrl(name);
    }
    return urls;
  }
}
