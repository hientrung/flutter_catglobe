import 'dart:convert';

enum ScriptRewriteMode { local, deploy }

// Consume comments and literals as tokens so their contents cannot be rewritten.
final _tokens = RegExp(
    r'''//[^\r\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[A-Za-z_][A-Za-z_0-9]*|[^\s]''');

String rewriteWorkflowReferences(
    String source, Object Function(String) resolve) {
  final tokens = _tokens
      .allMatches(source)
      .where((m) => !m[0]!.startsWith('//') && !m[0]!.startsWith('/*'))
      .toList();
  final out = StringBuffer();
  var start = 0;
  for (var i = 0; i + 4 < tokens.length; i++) {
    if (tokens[i][0] == 'new' &&
        tokens[i + 1][0] == 'WorkflowScript' &&
        tokens[i + 2][0] == '(' &&
        tokens[i + 3][0]!.startsWith('"') &&
        tokens[i + 4][0] == ')') {
      final literal = tokens[i + 3];
      out.write(source.substring(start, literal.start));
      out.write(resolve(jsonDecode(literal[0]!) as String));
      start = literal.end;
      i += 4;
    }
  }
  out.write(source.substring(start));
  return out.toString();
}

/// Shared rule pipeline. Local mode expands dependencies; deploy mode uses IDs.
class ScriptRewriter {
  ScriptRewriter(
      {required this.mode, required this.sources, this.ids = const {}});
  final ScriptRewriteMode mode;
  final Map<String, String> sources;
  final Map<String, int> ids;
  final _compiled = <String, String>{};
  final _active = <String>[];
  static const maxExpandedLength = 10 * 1024 * 1024;

  String rewrite(String key) {
    final cached = _compiled[key];
    if (cached != null) return cached;
    final source = sources[key];
    if (source == null) throw FormatException('Workflow not found: $key');
    if (_active.contains(key)) {
      throw FormatException(
          'Circular workflow reference: ${[..._active, key].join(' -> ')}');
    }
    if (_active.length >= 100)
      throw FormatException('Workflow nesting exceeds 100 levels');
    _active.add(key);
    try {
      var expandedLength = source.length;
      final result = rewriteWorkflowReferences(source, (target) {
        if (mode == ScriptRewriteMode.deploy) {
          final id = ids[target];
          if (id == null || id <= 0)
            throw FormatException('$key references missing workflow: $target');
          return id;
        }
        final replacement = '${jsonEncode(rewrite(target))}, false';
        expandedLength += replacement.length;
        if (expandedLength > maxExpandedLength)
          throw FormatException('Expanded CGScript exceeds 10 MiB');
        return replacement;
      });
      if (result.length > maxExpandedLength)
        throw FormatException('Expanded CGScript exceeds 10 MiB');
      return _compiled[key] = result;
    } finally {
      _active.removeLast();
    }
  }
}
