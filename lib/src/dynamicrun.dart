import 'dart:convert';

class DynamicRunException implements Exception {
  DynamicRunException(this.error);
  final Object error;

  @override
  String toString() => jsonEncode(error);
}

Object? parseDynamicRunResponse(String content, int statusCode) {
  final payload = jsonDecode(content);
  if (payload is! Map<String, dynamic>) {
    throw const FormatException('Invalid dynamicrun response');
  }
  final error = payload['error'];
  if (error != null) throw DynamicRunException(error);
  if (statusCode < 200 || statusCode >= 300) {
    throw StateError('Dynamicrun request failed ($statusCode)');
  }
  if (!payload.containsKey('result')) {
    throw const FormatException('Missing dynamicrun result');
  }
  return payload['result'];
}
