import 'package:catglobe_dev/src/script_rewriter.dart';
import 'package:test/test.dart';

void main() {
  test('mode aliases and directive casing select only matching blocks', () {
    for (final alias in [
      'test',
      'DEV',
      'Development',
      'prod',
      'Production',
      'LIVE',
      'release'
    ]) {
      final testMode =
          ['test', 'dev', 'development'].contains(alias.toLowerCase());
      final source = 'before\r\n #iF $alias\r\nactive\r\n #eNdIf\r\nafter';
      expect(filterScriptMode(source, isTest: testMode),
          'before\r\nactive\r\nafter');
      expect(filterScriptMode(source, isTest: !testMode), 'before\r\nafter');
    }
  });

  test(
      'nested blocks respect their parent and comments and strings are preserved',
      () {
    const source = '/*\n#IF unknown\n#ENDIF\n*/\n'
        'string s = "\n#IF unknown\n#ENDIF\n";\n'
        '#IF test\nyes\n#IF prod\nno\n#ENDIF\n#ENDIF\nend';
    expect(
        filterScriptMode(source, isTest: true),
        '/*\n#IF unknown\n#ENDIF\n*/\n'
        'string s = "\n#IF unknown\n#ENDIF\n";\nyes\nend');
  });

  test('invalid blocks fail instead of silently altering scripts', () {
    for (final source in [
      '#IF test\nx',
      '#ENDIF',
      '#IF unknown\nx\n#ENDIF',
      '#ENDIF extra'
    ]) {
      expect(
          () => filterScriptMode(source, isTest: true), throwsFormatException);
    }
  });

  test('excluded dependencies are removed before reference resolution', () {
    final sources = {
      'A': '#IF prod\nnew WorkflowScript("Missing");\n#ENDIF\n'
          '#IF dev\nnew WorkflowScript("B");\n#ENDIF',
      'B': '#IF test\nreturn true;\n#ENDIF',
    };
    expect(
        ScriptRewriter(mode: ScriptRewriteMode.local, sources: sources)
            .rewrite('A'),
        contains('new WorkflowScript("return true;\\n", false)'));
    expect(
        ScriptRewriter(
            mode: ScriptRewriteMode.deploy,
            sources: sources,
            ids: {'B': 42}).rewrite('A'),
        contains('new WorkflowScript(42)'));
  });
}
