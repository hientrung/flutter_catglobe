import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'config.dart';
import 'cgs_file.dart';
import 'flutter_assets.dart';
import 'script_rewriter.dart';
export 'script_rewriter.dart' show rewriteWorkflowReferences;

typedef ScriptRunner = Future<Object?> Function(String script);

/// Optional site-specific deployment overrides.
abstract class DeploymentAssets {
  /// Uploads exact bytes under [dashboardId], preserving relative paths.
  /// Returns the directory URL from which Flutter can load every uploaded file.
  Future<Uri> upload(int dashboardId, Map<String, List<int>> files);

  /// Returns CGScript setting anonymous execution to the requested value.
  String anonymousScript(int workflowId, bool enabled);
}

class LocalWorkflow {
  LocalWorkflow(this.key, this.source, this.runAs, this.isPublic);
  final String key;
  final String source;
  final int runAs;
  final bool isPublic;

  factory LocalWorkflow.parse(String path, String source) {
    if (p.posix.isAbsolute(path) ||
        p.posix.split(path).any((s) => s == '..' || s == '.') ||
        path.contains('\\')) {
      throw FormatException('Invalid script path: $path');
    }
    final match = RegExp(r'^(.+?)(?:@([1-9][0-9]*))?(\.public)?\.cgs$')
        .firstMatch(p.posix.basename(path));
    if (match == null || match[1]!.contains('@')) {
      throw FormatException('Invalid CGScript filename: $path');
    }
    final user = int.tryParse(match[2] ?? '') ?? 0;
    final public = match[3] != null;
    if (public && user == 0) {
      throw FormatException('Public workflow requires @userId: $path');
    }
    return LocalWorkflow(
        p.posix.normalize(p.posix.join(p.posix.dirname(path), match[1]!)),
        source,
        user,
        public);
  }

  String compile(Map<String, int> ids, {bool isTest = true}) => ScriptRewriter(
          mode: ScriptRewriteMode.deploy,
          sources: {key: source},
          ids: ids,
          isTest: isTest)
      .rewrite(key);
  @override
  String toString() => key;
}

String cgString(String value) => jsonEncode(value);

String findResource(String name, String type, String parent) => '''
array matches = Resource_searchByName(${cgString(name)}, $type, 0, StringSearchType_Equal, 2, $parent, false);
if (matches.Count > 1) throw "Duplicate deployment resource";
number resourceId = 0;
if (matches.Count == 1) resourceId = matches[0].ResourceId;
''';

String folderScript(String name, int parent) => '''
${findResource(name, 'Resource_Type_Folder', '$parent')}
if (resourceId == 0) {
  Folder folder = new Folder(${cgString(name)}, 0, $parent);
  folder.Folder_save();
  resourceId = folder.ResourceId;
}
return resourceId;
''';

String reserveWorkflowScript(String name, int parent) => '''
${findResource(name, 'Resource_Type_WorkFlow', '$parent')}
if (resourceId == 0) {
  WorkflowScript workflow = new WorkflowScript("return empty;", false);
  workflow.Save(${cgString(name)}, $parent);
  resourceId = workflow.UniqueId;
}
return resourceId;
''';

String updateWorkflowScript(int id, LocalWorkflow workflow, String source,
        String anonymousScript) =>
    '''
WorkflowScript workflow = new WorkflowScript($id);
workflow.CgScript = ${cgString(source)};
workflow.ImpersonatedUser = ${workflow.runAs};
workflow.Save();
$anonymousScript
return workflow.UniqueId;
''';

String anonymousWorkflowScript(int workflowId, bool enabled) => '''
User anonymousUser = User_getUserByUsername("anonymous");
${enabled ? 'if (anonymousUser == empty) throw "Anonymous user not found";' : ''}
if (anonymousUser != empty) {
  Dictionary anonymousPermissions = new Dictionary();
  anonymousPermissions.Add(anonymousUser.ResourceId, "${enabled ? 'Access' : 'None'}");
  updateUserResourceIdPermission($workflowId, anonymousPermissions);
}
''';

String dashboardScript(String name, int parent, String? html) => '''
${findResource(name, 'Resource_Type_Dashboard', '$parent')}
Dashboard dashboard;
if (resourceId == 0) {
  dashboard = new Dashboard("", ${cgString(name)}, "en-US");
  dashboard.Save(${cgString(name)}, $parent);
} else {
  dashboard = new Dashboard(resourceId);
}
${html == null ? '' : 'dashboard.Layout = ${cgString(html)};\ndashboard.Save();'}
return dashboard.UniqueId;
''';

String workflowMapScript(Map<String, int> ids) =>
    'globalThis.catglobeWorkflowIds = Object.freeze(${jsonEncode(ids).replaceAll('<', r'\u003c')});';

String prepareDashboardHtml(String html, Map<String, int> ids, Uri assets) {
  if (!assets.isAbsolute ||
      assets.scheme != 'https' ||
      !assets.path.endsWith('/') ||
      assets.hasQuery ||
      assets.hasFragment) {
    throw FormatException('Asset uploader must return an HTTPS directory URL');
  }
  final head = RegExp(r'<head\b[^>]*>', caseSensitive: false).firstMatch(html);
  if (head == null)
    throw FormatException('Build index.html has no head element');
  html = html.replaceAll(RegExp(r'<base\b[^>]*>', caseSensitive: false), '');
  final insert =
      RegExp(r'<head\b[^>]*>', caseSensitive: false).firstMatch(html)!.end;
  final url =
      assets.toString().replaceAll('&', '&amp;').replaceAll('"', '&quot;');
  return html.substring(0, insert) +
      '<base href="$url"><script>${workflowMapScript(ids)}</script>' +
      html.substring(insert);
}

/// Deploys local workflows and an optional Flutter build to Catglobe.
class CatglobeDeployment {
  /// Creates a deployment service using [run] and optional asset upload support.
  CatglobeDeployment(this.run, {this.assets, this.fileUploader});

  /// The authenticated CGScript executor used to create and update resources.
  final ScriptRunner run;

  /// The optional site-specific asset uploader and permission script builder.
  final DeploymentAssets? assets;

  /// The standard Files API uploader used when [assets] is absent.
  final CgsFileUploader? fileUploader;

  /// Deploys [config] to the `test` or `production` environment specified by [mode].
  ///
  /// Set [includeBuild] to `false` to deploy workflows only. Reserves workflow
  /// IDs before rewriting references, allowing cyclic deployed dependencies.
  /// Returns `mode`, `workflowIds`, and a nullable `dashboardId`.
  /// Workflows are stored directly in `Test Script` or `Live Script`, with path
  /// segments joined by underscores. Lookup keys retain their original paths.
  /// Conflicting flattened names are rejected before remote writes.
  ///
  /// Validates local inputs before writing remote resources. Throws
  /// [FormatException] for invalid settings or sources and [StateError] when
  /// a build requires an uploader but none is configured. Remote errors
  /// propagate; resources already written are not rolled back.
  Future<Map<String, Object?>> deploy(ProjectConfig config, String mode,
      {bool includeBuild = true}) async {
    if (mode != 'test' && mode != 'production')
      throw FormatException('Invalid deployment mode');
    final rootId = int.tryParse(config.value('rootFolderId'));
    if (rootId == null || rootId <= 0)
      throw FormatException('rootFolderId must be a positive resource ID');
    final scripts =
        await readDeploymentFiles(config, 'scriptDirectory', 'cgscript');
    final workflows = <String, LocalWorkflow>{};
    final deploymentNames = <String, String>{};
    for (final entry in scripts.entries) {
      if (p.posix.extension(entry.key) != '.cgs') continue;
      final workflow = LocalWorkflow.parse(entry.key, utf8.decode(entry.value));
      if (workflows.containsKey(workflow.key))
        throw FormatException('Duplicate workflow key: ${workflow.key}');
      final name = p.posix.split(workflow.key).join('_');
      final previous = deploymentNames[name];
      if (previous != null) {
        throw FormatException(
            'Duplicate deployment workflow name "$name": $previous and ${workflow.key}');
      }
      deploymentNames[name] = workflow.key;
      workflows[workflow.key] = workflow;
    }
    // All local validation precedes remote writes.
    final dummyIds = {for (final key in workflows.keys) key: 1};
    for (final workflow in workflows.values) {
      workflow.compile(dummyIds, isTest: mode == 'test');
    }
    final build = includeBuild
        ? await readDeploymentFiles(config, 'buildDirectory', 'build/web')
        : <String, List<int>>{};
    String? html;
    if (includeBuild) {
      if (!build.containsKey('index.html'))
        throw FormatException('Build requires index.html');
      html = utf8.decode(build['index.html']!);
      prepareDashboardHtml(html, {}, Uri.parse('https://preflight.invalid/'));
    }
    if (includeBuild && assets == null && fileUploader == null) {
      throw StateError(
          'A CgsFileUploader is required. No resources were changed.');
    }
    if (includeBuild && assets == null) {
      for (final entry in build.entries) {
        CgsFileUploader.storageName(1, entry.key);
      }
    }
    final ids = <String, int>{};
    final modeFolder = await _id(
        folderScript(mode == 'test' ? 'Test Script' : 'Live Script', rootId));

    for (final entry in deploymentNames.entries) {
      ids[entry.value] =
          await _id(reserveWorkflowScript(entry.key, modeFolder));
    }
    final deployedAt = DateTime.now().toUtc().toIso8601String();
    for (final workflow in workflows.values) {
      final id = ids[workflow.key]!;
      await run(updateWorkflowScript(
          id,
          workflow,
          '// Automatically deployed on $deployedAt (UTC). Manual edits will be overwritten on the next deployment.\n'
          '${workflow.compile(ids, isTest: mode == 'test')}',
          assets?.anonymousScript(id, workflow.isPublic) ??
              anonymousWorkflowScript(id, workflow.isPublic)));
    }
    int? dashboardId;
    if (includeBuild) {
      final name = mode == 'test' ? 'Test portal' : 'Live portal';
      dashboardId = await _id(dashboardScript(name, rootId, null));
      build['catglobe-workflows.js'] = utf8.encode(workflowMapScript(ids));
      build.remove('index.html');
      if (assets != null) {
        final base = await assets!.upload(dashboardId, build);
        await run(dashboardScript(
            name, rootId, prepareDashboardHtml(html!, ids, base)));
      } else {
        final uploader = fileUploader!;
        final urls = {
          for (final path in build.keys)
            path: uploader
                .downloadUrl(CgsFileUploader.storageName(dashboardId, path))
        };
        final transformed = <String, List<int>>{};
        for (final entry in build.entries) {
          transformed[entry.key] = ['.js', '.mjs', '.css']
                  .contains(p.posix.extension(entry.key))
              ? utf8.encode(
                  rewriteAssetText(utf8.decode(entry.value), entry.key, urls))
              : entry.value;
        }
        await uploader.upload(dashboardId, transformed);
        final base =
            uploader.issuer.resolve('/__catglobe_flutter__/$dashboardId/');
        await run(dashboardScript(
            name, rootId, prepareFlatDashboardHtml(html!, ids, urls, base)));
      }
    }
    return {'mode': mode, 'workflowIds': ids, 'dashboardId': dashboardId};
  }

  Future<int> _id(String script) async {
    final result = await run(script);
    if (result is! num || result <= 0 || result != result.toInt()) {
      throw FormatException(
          'Expected a positive Catglobe resource ID, received $result');
    }
    return result.toInt();
  }
}

Future<Map<String, List<int>>> readDeploymentFiles(
    ProjectConfig config, String setting, String fallback) async {
  final relative =
      config.value(setting).isEmpty ? fallback : config.value(setting);
  if (p.isAbsolute(relative))
    throw FormatException('$setting must be relative to project');
  final root =
      await Directory(config.value('projectPath')).resolveSymbolicLinks();
  final directory =
      await Directory(p.join(root, relative)).resolveSymbolicLinks();
  if (!p.isWithin(root, directory))
    throw FormatException('$setting escapes project');
  final files = <String, List<int>>{};
  var size = 0;
  final entries = await Directory(directory)
      .list(recursive: true, followLinks: false)
      .toList();
  entries.sort((a, b) => a.path.compareTo(b.path));
  for (final entry in entries.whereType<File>()) {
    size += await entry.length();
    if (size > 50 * 1024 * 1024) throw StateError('Deployment exceeds 50 MiB');
    files[p.posix.joinAll(p.split(p.relative(entry.path, from: directory)))] =
        await entry.readAsBytes();
  }
  return files;
}
