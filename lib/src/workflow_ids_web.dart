import 'dart:js_interop';

@JS('catglobeWorkflowIds')
external JSAny? get _workflowIds;

Map<String, int> readWorkflowIds() {
  final value = _workflowIds?.dartify();
  if (value is! Map) return {};
  return {
    for (final entry in value.entries)
      if (entry.key is String &&
          entry.value is num &&
          entry.value > 0 &&
          entry.value == entry.value.toInt())
        entry.key as String: (entry.value as num).toInt()
  };
}
