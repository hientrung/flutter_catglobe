import 'package:catglobe/src/flutter_assets.dart';
import 'package:test/test.dart';

void main() {
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
}
