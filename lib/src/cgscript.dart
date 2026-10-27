import 'dart:convert';

class CgScriptException implements Exception {
  CgScriptException(this.error);
  final Object error;

  @override
  String toString() => jsonEncode(error);
}

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
