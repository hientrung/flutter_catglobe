import 'dart:convert';

enum ScriptRewriteMode { local, deploy }

/// Filters standalone `#IF mode` blocks for test/local or production execution.
///
/// Recognizes `test`, `dev`, and `development` when [isTest] is true, and
/// `prod`, `production`, `live`, and `release` otherwise, ignoring case.
/// Removes directive lines and excluded blocks while preserving other code.
/// Supports nested blocks and ignores directives inside comments and literals.
/// Throws [FormatException] for unknown modes or unbalanced directives.
String filterScriptMode(String source, {required bool isTest}) {
  final protected = _tokens
      .allMatches(source)
      .where((m) =>
          m[0]!.startsWith('//') ||
          m[0]!.startsWith('/*') ||
          m[0]!.startsWith('"') ||
          m[0]!.startsWith("'"))
      .toList();
  final directives = RegExp(r'^[ \t]*#(IF\b[^\r\n]*|ENDIF\b[^\r\n]*)\r?$',
      multiLine: true, caseSensitive: false);
  final stack = <bool>[];
  final out = StringBuffer();
  var offset = 0;
  var protectedIndex = 0;
  for (final match in directives.allMatches(source)) {
    final hash = source.indexOf('#', match.start);
    while (protectedIndex < protected.length &&
        protected[protectedIndex].end <= hash) {
      protectedIndex++;
    }
    if (protectedIndex < protected.length &&
        protected[protectedIndex].start <= hash) continue;
    if (stack.every((enabled) => enabled))
      out.write(source.substring(offset, match.start));
    final directive = match[1]!.trim().toLowerCase();
    if (directive == 'endif') {
      if (stack.isEmpty) throw const FormatException('Unexpected #ENDIF');
      stack.removeLast();
    } else if (directive.startsWith('if ') || directive.startsWith('if\t')) {
      final mode = directive.substring(2).trim();
      const testModes = ['test', 'dev', 'development'];
      const productionModes = ['prod', 'production', 'live', 'release'];
      if (!testModes.contains(mode) && !productionModes.contains(mode)) {
        throw FormatException('Unknown #IF mode: $mode');
      }
      stack.add(
          isTest ? testModes.contains(mode) : productionModes.contains(mode));
    } else {
      throw FormatException('Invalid directive: ${match[0]}');
    }
    offset = match.end;
    if (offset < source.length && source[offset] == '\n') offset++;
  }
  if (stack.isNotEmpty) throw const FormatException('Missing #ENDIF');
  out.write(source.substring(offset));
  return out.toString();
}

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
      {required this.mode,
      required this.sources,
      this.ids = const {},
      this.isTest = true});
  final ScriptRewriteMode mode;
  final Map<String, String> sources;
  final Map<String, int> ids;

  /// Whether conditional blocks use the test/local environment.
  final bool isTest;
  final _compiled = <String, String>{};
  final _active = <String>[];
  static const maxExpandedLength = 10 * 1024 * 1024;

  String rewrite(String key) {
    final cached = _compiled[key];
    if (cached != null) return cached;
    final original = sources[key];
    if (original == null) throw FormatException('Workflow not found: $key');
    final source = filterScriptMode(original, isTest: isTest);
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
