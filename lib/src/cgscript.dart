import 'dart:convert';

/// A non-null error returned in a Catglobe script response.
class CgScriptException implements Exception {
  /// Creates an exception preserving the original [error] value.
  CgScriptException(this.error);

  /// The decoded Catglobe error value, which may be structured JSON.
  final Object error;

  @override
  String toString() => jsonEncode(error);
}

/// Decodes a Catglobe response and returns its result, including `null`.
///
/// Throws [CgScriptException] for a non-null script error, [StateError] for
/// an unsuccessful [statusCode] without a script error, and [FormatException]
/// for invalid JSON or a missing result.
Object? parseCgScriptResponse(String content, int statusCode) {
  final payload = jsonDecode(content);
  if (payload is! Map<String, dynamic>) {
    throw const FormatException('Invalid CgScript run response');
  }
  final error = payload['error'];
  if (error != null) throw CgScriptException(error);
  if (statusCode < 200 || statusCode >= 300) {
    throw StateError('CgScript run request failed ($statusCode)');
  }
  if (!payload.containsKey('result')) {
    throw const FormatException('Missing CgScript run result');
  }
  return payload['result'];
}
