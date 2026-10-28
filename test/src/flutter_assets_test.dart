import 'dart:convert';
import 'dart:io';
import 'package:catglobe/src/flutter_assets.dart';
import 'package:test/test.dart';

void main() {
  test(
      'Flutter Trusted Types validates mapped script URLs without loading base',
      () async {
    final temp = await Directory.systemTemp.createTemp('catglobe-runtime-');
    addTearDown(() => temp.delete(recursive: true));
    final script = File('${temp.path}/runtime.cjs');
    await script.writeAsString(r'''
const vm = require('node:vm');
const assert = require('node:assert/strict');
const runtime = JSON.parse(process.argv[2]);
for (const trusted of [false, true]) {
  const scripts = [];
  class Element { setAttribute() {} }
  class Script extends Element {
    set src(value) { scripts.push(String(value)); }
  }
  const context = {
    URL, Request, fetch: async () => {}, Element,
    HTMLScriptElement: Script, HTMLImageElement: class extends Element {},
    HTMLLinkElement: class extends Element {}, HTMLMediaElement: class extends Element {},
    HTMLSourceElement: class extends Element {}, XMLHttpRequest: class { open() {} },
    document: {baseURI: 'https://site.test/__catglobe_flutter__/42/'},
  };
  if (trusted) context.trustedTypes = {
    createPolicy: (name, rules) => ({createScriptURL: input => rules.createScriptURL(input) ?? ''})
  };
  vm.createContext(context);
  vm.runInContext(runtime, context);
  vm.runInContext(`
    const policy = globalThis.trustedTypes?.createPolicy('flutter-js', {
      createScriptURL(input) {
        const parsed = new URL(input, document.baseURI);
        if (/\\.m?js$/.test(parsed.pathname)) return parsed.toString();
      }
    });
    const source = new URL('main.dart.js', document.baseURI).href;
    const script = new HTMLScriptElement();
    script.src = policy ? policy.createScriptURL(source) : source;
    if (policy && policy.createScriptURL('https://unmapped.test/file.txt') !== '') {
      throw Error('Invalid extension was accepted');
    }
  `, context);
  assert.deepEqual(scripts, ['https://site.test/CgScript/File?file=42_main.js&v=build123']);
}
''');
    final runtime = assetRuntime({
      'main.dart.js': Uri.parse(
          'https://site.test/CgScript/File?file=42_main.js&v=build123'),
    }, Uri.parse('https://site.test/__catglobe_flutter__/42/'));
    final result =
        await Process.run('node', [script.path, jsonEncode(runtime)]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });

  final urls = {
    'flutter_bootstrap.js':
        Uri.parse('https://site.test/ol/Public/CgsFile.aspx?file=42_boot.js'),
    'icons/icon.png':
        Uri.parse('https://site.test/ol/Public/CgsFile.aspx?file=42_icon.png'),
    'assets/font.woff2': Uri.parse(
        'https://site.test/ol/Public/CgsFile.aspx?file=42_font.woff2'),
    'modules/helper.mjs': Uri.parse(
        'https://site.test/ol/Public/CgsFile.aspx?file=42_helper.mjs'),
  };
  test('HTML asset replacement and runtime precede bootstrap', () {
    final html = prepareFlatDashboardHtml(
        '<html><head><base href="/"><link href="icons/icon.png"></head><body><script src="flutter_bootstrap.js"></script></body></html>',
        {'Folder/A': 123},
        urls,
        Uri.parse('https://site.test/__catglobe_flutter__/42/'));
    expect('<base'.allMatches(html).length, 1);
    expect(html, contains('src="${urls['flutter_bootstrap.js']}"'));
    expect(html, contains('href="${urls['icons/icon.png']}"'));
    expect(html.indexOf('globalThis.fetch ='),
        lessThan(html.indexOf('<script src=')));
    expect(html, contains('Folder/A'));
  });
  test('CSS URL replacement preserves fragment and external resources', () {
    final css = rewriteAssetText(
        'a{src:url("../assets/font.woff2#v1");background:url(https://external.test/image.png)}',
        'css/styles.css',
        urls);
    expect(css, contains('${urls['assets/font.woff2']}#v1'));
    expect(css, contains('https://external.test/image.png'));
  });
  test('module imports resolve relative to their source without rewriting data',
      () {
    final js = rewriteAssetText('''
import x from "./helper.mjs";
export {x} from './helper.mjs';
const lazy = import("./helper.mjs");
const name = "./helper.mjs";
''', 'modules/main.mjs', urls);
    expect(urls['modules/helper.mjs'].toString().allMatches(js).length, 3);
    expect(js, contains('const name = "./helper.mjs"'));
  });

  test('source map comments use uploaded URLs or drop missing local maps', () {
    final mapped =
        Uri.parse('https://site.test/CgScript/File?file=42_map.js.map');
    expect(
        rewriteAssetText('code();\n//# sourceMappingURL=flutter.js.map\r\n',
            'flutter_bootstrap.js', {}),
        'code();\n\n');
    expect(
        rewriteAssetText('//# sourceMappingURL=flutter.js.map',
            'flutter_bootstrap.js', {'flutter.js.map': mapped}),
        '//# sourceMappingURL=$mapped');
    for (final url in [
      'https://cdn.test/code.map',
      'data:application/json;base64,e30='
    ]) {
      final source = '//# sourceMappingURL=$url';
      expect(rewriteAssetText(source, 'main.js', {}), source);
    }
    const literal = 'const text = "sourceMappingURL=missing.map";';
    expect(rewriteAssetText(literal, 'main.js', {}), literal);
  });
}
