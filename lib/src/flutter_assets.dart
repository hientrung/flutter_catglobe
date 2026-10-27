import 'dart:convert';
import 'package:path/path.dart' as p;

String _safeJson(Object value) => jsonEncode(value).replaceAll('<', r'\u003c');

/// Maps a virtual build directory onto individual CgsFile query URLs.
String assetRuntime(Map<String, Uri> urls, Uri virtualBase) => '''
globalThis.catglobeAssetUrls = Object.freeze(${_safeJson(urls.map((k, v) => MapEntry(k, v.toString())))});
globalThis.catglobeAssetBase = ${_safeJson(virtualBase.toString())};
$_runtime
''';

const _runtime = r'''
(() => {
  const NativeURL = globalThis.URL;
  const base = globalThis.catglobeAssetBase;
  const forward = new Map(), reverse = new Map();
  for (const [path, target] of Object.entries(globalThis.catglobeAssetUrls)) {
    const virtual = new NativeURL(path, base).href;
    forward.set(virtual, target);
    reverse.set(new NativeURL(target).href, virtual);
  }
  const resolve = (input, relativeTo = document.baseURI) => {
    const sourceBase = reverse.get(String(relativeTo)) || relativeTo;
    const url = new NativeURL(String(input), sourceBase);
    // Flutter cache-busting parameters are irrelevant: names are deployment scoped.
    const clean = new NativeURL(url.href); clean.search = ''; clean.hash = '';
    const target = forward.get(clean.href);
    return target ? target + url.hash : url.href;
  };
  globalThis.catglobeAssetUrl = resolve;
  // Flutter constructs module/WASM URLs before dynamic import. Translate at
  // construction, including URLs relative to an uploaded module's import.meta.url.
  globalThis.URL = class extends NativeURL {
    constructor(input, relativeTo) {
      super(resolve(input, relativeTo === undefined ? base : relativeTo));
    }
  };
  const nativeFetch = globalThis.fetch.bind(globalThis);
  globalThis.fetch = (input, init) => {
    if (input instanceof Request) {
      const target = resolve(input.url);
      return nativeFetch(target === input.url ? input : new Request(target, input), init);
    }
    return nativeFetch(resolve(input), init);
  };
  const nativeOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function(method, url, ...args) {
    return nativeOpen.call(this, method, resolve(url), ...args);
  };
  // Covers dynamically created entrypoint scripts, images, audio and fonts.
  for (const [type, property] of [
    [HTMLScriptElement, 'src'], [HTMLImageElement, 'src'],
    [HTMLLinkElement, 'href'], [HTMLMediaElement, 'src'],
    [HTMLSourceElement, 'src']
  ]) {
    const descriptor = Object.getOwnPropertyDescriptor(type.prototype, property);
    if (!descriptor || !descriptor.set) continue;
    Object.defineProperty(type.prototype, property, {
      ...descriptor, set(value) { descriptor.set.call(this, resolve(value)); }
    });
  }
  const nativeSetAttribute = Element.prototype.setAttribute;
  Element.prototype.setAttribute = function(name, value) {
    return nativeSetAttribute.call(this, name,
      /^(src|href|poster)$/i.test(name) ? resolve(value) : value);
  };
})();
''';

String rewriteAssetText(String text, String file, Map<String, Uri> urls) {
  String resolve(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.hasScheme ||
        value.startsWith('//') ||
        value.startsWith('#')) return value;
    final path = p.posix.normalize(
        p.posix.join(p.posix.dirname(file), Uri.decodeComponent(uri.path)));
    final target = urls[path];
    return target == null
        ? value
        : target
            .replace(fragment: uri.hasFragment ? uri.fragment : null)
            .toString();
  }

  final extension = p.posix.extension(file);
  if (extension == '.html') {
    return text.replaceAllMapped(
        RegExp(r'''\b(src|href|poster)\s*=\s*(["'])(.*?)\2''',
            caseSensitive: false),
        (m) =>
            '${m[1]}=${m[2]}${resolve(m[3]!).replaceAll('&', '&amp;')}${m[2]}');
  }
  if (extension == '.css') {
    return text.replaceAllMapped(
        RegExp(r'''url\(\s*(["']?)([^)'"\s]+)\1\s*\)'''),
        (m) => 'url("${resolve(m[2]!)}")');
  }
  if (extension == '.js' || extension == '.mjs') {
    // Static module specifiers bypass fetch and the URL constructor.
    return text.replaceAllMapped(
        RegExp(
            r'''(\b(?:import|export)\s+(?:[^;\n]*?\s+from\s*)?|\bimport\s*\(\s*)(["'])([^"']+)\2'''),
        (m) => '${m[1]}${m[2]}${resolve(m[3]!)}${m[2]}');
  }
  return text;
}

String prepareFlatDashboardHtml(
    String html, Map<String, int> ids, Map<String, Uri> urls, Uri base) {
  html = html.replaceAll(RegExp(r'<base\b[^>]*>', caseSensitive: false), '');
  html = rewriteAssetText(html, 'index.html', urls);
  final head = RegExp(r'<head\b[^>]*>', caseSensitive: false).firstMatch(html);
  if (head == null)
    throw FormatException('Build index.html has no head element');
  final injection = '<base href="${base.toString()}"><script>'
      'globalThis.catglobeWorkflowIds = Object.freeze(${_safeJson(ids)});\n'
      '${assetRuntime(urls, base)}</script>';
  return html.substring(0, head.end) + injection + html.substring(head.end);
}
