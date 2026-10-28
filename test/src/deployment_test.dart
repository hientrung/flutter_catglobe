import 'dart:convert';
import 'dart:io';
import 'package:catglobe/src/config.dart';
import 'package:catglobe/src/deployment.dart';
import 'package:catglobe/src/file_uploader.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class FakeAssets implements DeploymentAssets {
  int? dashboard;
  Map<String, List<int>>? uploaded;
  @override
  String anonymousScript(int workflowId, bool enabled) =>
      '// anonymous=$enabled';
  @override
  Future<Uri> upload(int dashboardId, Map<String, List<int>> files) async {
    dashboard = dashboardId;
    uploaded = files;
    return Uri.parse('https://example.com/files/$dashboardId/');
  }
}

class FlatUploadClient extends http.BaseClient {
  final uploaded = <String, List<int>>{};
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final upload = request as http.Request;
    final name = upload.url.pathSegments.last;
    uploaded[name] = upload.bodyBytes;
    return http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode({
          'success': true,
          'filename': name,
          'isTemp': false,
          'size': upload.bodyBytes.length
        }))),
        201);
  }
}

void main() {
  test('filename metadata is excluded from the path key', () {
    final w = LocalWorkflow.parse('Folder/A@123.public.cgs', 'return true;');
    expect(w.key, 'Folder/A');
    expect(w.runAs, 123);
    expect(w.isPublic, isTrue);
    expect(LocalWorkflow.parse('A.cgs', '').runAs, 0);
    for (final path in ['A.public.cgs', 'A@x.cgs', 'A@0.cgs', '../A.cgs']) {
      expect(() => LocalWorkflow.parse(path, ''), throwsFormatException);
    }
  });

  test('rewrites only constructor references outside comments and literals',
      () {
    const source = '''
// new WorkflowScript("Missing")
/* new WorkflowScript("Missing") */
string text = "new WorkflowScript(\\"Missing\\")";
new /* comment */ WorkflowScript ( "Folder/B" ).Call();
new WorkflowScript(123).Call();
''';
    final compiled = rewriteWorkflowReferences(source, (key) {
      expect(key, 'Folder/B');
      return 42;
    });
    expect(compiled, contains('WorkflowScript ( 42 )'));
    expect(compiled, contains('// new WorkflowScript("Missing")'));
    expect(compiled, contains('new WorkflowScript(123)'));
    expect(
        () => LocalWorkflow.parse('A.cgs', 'new WorkflowScript("B");')
            .compile({}),
        throwsFormatException);
  });

  test('HTML map precedes bootstrap and replaces existing base', () {
    final html = prepareDashboardHtml(
        '<html><head><base href="/"><script src="flutter_bootstrap.js"></script></head></html>',
        {'A</script>': 42},
        Uri.parse('https://example.com/files/7/'));
    expect('<base'.allMatches(html).length, 1);
    expect(html, contains('href="https://example.com/files/7/"'));
    expect(html, contains(r'A\u003c/script>'));
    expect(html.indexOf('catglobeWorkflowIds'),
        lessThan(html.indexOf('flutter_bootstrap.js')));
  });

  late Directory temp;
  late ProjectConfig config;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('catglobe-deploy-');
    config = ProjectConfig({
      'id': 'one',
      'name': 'one',
      'projectPath': temp.path,
      'issuer': 'https://example.com/',
      'rootFolderId': '10'
    });
    await Directory(p.join(temp.path, 'cgscript', 'Folder'))
        .create(recursive: true);
    await File(p.join(temp.path, 'cgscript', 'A.cgs'))
        .writeAsString('new WorkflowScript("Folder/B").Call();');
    await File(p.join(temp.path, 'cgscript', 'Folder', 'B.cgs'))
        .writeAsString('new WorkflowScript("A").Call();');
    await Directory(p.join(temp.path, 'build', 'web')).create(recursive: true);
    await File(p.join(temp.path, 'build', 'web', 'index.html'))
        .writeAsString('<html><head></head></html>');
    await File(p.join(temp.path, 'build', 'web', 'main.wasm'))
        .writeAsBytes([0, 255, 128, 1]);
  });
  tearDown(() => temp.delete(recursive: true));

  test('build scan excludes metadata, CanvasKit and assets/NOTICES', () async {
    final build = p.join(temp.path, 'build', 'web');
    for (final path in [
      '.last_build_id',
      'assets/NOTICES',
      'assets/NOTICES.txt',
      'canvaskit/canvaskit.js',
      'canvaskit/chromium/canvaskit.wasm',
      'assets/canvaskit/icon.png',
    ]) {
      final file = File(p.joinAll([build, ...path.split('/')]));
      await file.parent.create(recursive: true);
      await file.writeAsString('content');
    }
    final files =
        await readDeploymentFiles(config, 'buildDirectory', 'build/web');
    expect(
        files.keys,
        unorderedEquals([
          'index.html',
          'main.wasm',
          'assets/NOTICES.txt',
          'assets/canvaskit/icon.png',
        ]));
    await File(p.join(temp.path, 'cgscript', '.last_build_id'))
        .writeAsString('source');
    final scripts =
        await readDeploymentFiles(config, 'scriptDirectory', 'cgscript');
    expect(scripts, contains('.last_build_id'));
  });

  for (final mode in ['test', 'production']) {
    test('$mode filters blocks and adds a UTC deployment notice', () async {
      await File(p.join(temp.path, 'cgscript', 'A.cgs'))
          .writeAsString('#IF dev\nreturn "testing";\n#ENDIF\n'
              '#IF RELEASE\nreturn "production";\n#ENDIF\n');
      final scripts = <String>[];
      final before = DateTime.now().toUtc();
      await CatglobeDeployment((s) async {
        scripts.add(s);
        return 123;
      }).deploy(config, mode, includeBuild: false);
      final update = scripts.firstWhere((s) => s.contains('workflow.CgScript'));
      final match = RegExp(r'workflow.CgScript = (".*");').firstMatch(update)!;
      final source = jsonDecode(match[1]!) as String;
      expect(source, startsWith('// Automatically deployed on '));
      expect(source,
          contains('Manual edits will be overwritten on the next deployment.'));
      final timestamp = source.split(' on ')[1].split(' (UTC)')[0];
      final deployed = DateTime.parse(timestamp);
      expect(deployed.isUtc, isTrue);
      expect(deployed.isBefore(before), isFalse);
      expect(deployed.isAfter(DateTime.now().toUtc()), isFalse);
      expect(
          source,
          contains(
              mode == 'test' ? 'return "testing";' : 'return "production";'));
      expect(
          source,
          isNot(contains(
              mode == 'test' ? 'return "production";' : 'return "testing";')));
      expect(source, isNot(contains('#IF')));
    });
  }

  for (final mode in ['test', 'production']) {
    test('$mode deploy flattens nested names into the mode folder', () async {
      final nested =
          Directory(p.join(temp.path, 'cgscript', 'FolderA', 'SubA'));
      await nested.create(recursive: true);
      await File(p.join(nested.path, 'NameWorkflow@123.public.cgs'))
          .writeAsString('new WorkflowScript("Folder/B").Call();');
      final scripts = <String>[];
      var nextId = 100;
      final result = await CatglobeDeployment((script) async {
        scripts.add(script);
        return ++nextId;
      }).deploy(config, mode, includeBuild: false);
      expect(scripts.where((s) => s.contains('new Folder(')), hasLength(1));
      expect(scripts.first,
          contains(mode == 'test' ? 'Test Script' : 'Live Script'));
      final reservations = scripts.where((s) => s.contains('return empty;'));
      expect(reservations, hasLength(3));
      expect(
          reservations.any((s) =>
              s.contains('workflow.Save("FolderA_SubA_NameWorkflow", 101)')),
          isTrue);
      expect(
          reservations.any((s) => s.contains('workflow.Save("Folder_B", 101)')),
          isTrue);
      final ids = result['workflowIds'] as Map<String, int>;
      expect(result['uploadedFiles'], isEmpty);
      expect(ids.keys, contains('FolderA/SubA/NameWorkflow'));
      final update = scripts
          .singleWhere((s) => s.contains('workflow.ImpersonatedUser = 123'));
      expect(update, contains('new WorkflowScript(${ids['Folder/B']})'));
    });
  }

  test('flattened name collisions fail before any remote write', () async {
    await File(p.join(temp.path, 'cgscript', 'Folder_B.cgs'))
        .writeAsString('return true;');
    var calls = 0;
    final deployer = CatglobeDeployment((_) async {
      calls++;
      return 100;
    });
    await expectLater(
        deployer.deploy(config, 'test', includeBuild: false),
        throwsA(isA<FormatException>().having((e) => e.message, 'message',
            allOf(contains('Folder_B'), contains('Folder/B')))));
    expect(calls, 0);
  });

  test(
      'two passes support cycles and upload preserves bytes under dashboard ID',
      () async {
    final scripts = <String>[];
    final assets = FakeAssets();
    var id = 100;
    final result = await CatglobeDeployment((script) async {
      scripts.add(script);
      return ++id;
    }, assets: assets)
        .deploy(config, 'test');
    final ids = result['workflowIds'] as Map<String, int>;
    final updates =
        scripts.where((s) => s.contains('workflow.CgScript')).toList();
    expect(updates.length, 2);
    expect(updates[0], contains('new WorkflowScript(${ids['Folder/B']})'));
    expect(updates[1], contains('new WorkflowScript(${ids['A']})'));
    expect(
        scripts.indexOf(updates.first),
        greaterThan(
            scripts.lastIndexWhere((s) => s.contains('return empty;'))));
    expect(scripts.first, contains('Test Script'));
    expect(scripts.last, contains('Test portal'));
    expect(assets.dashboard, result['dashboardId']);
    expect(result['uploadedFiles'], ['catglobe-workflows.js', 'main.wasm']);
    expect(assets.uploaded!['main.wasm'], [0, 255, 128, 1]);
    expect(assets.uploaded!.containsKey('index.html'), isFalse);
    expect(utf8.decode(assets.uploaded!['catglobe-workflows.js']!),
        contains('Folder/B'));
    expect(scripts.last, contains('catglobeWorkflowIds'));
  });

  test('unsupported upload and missing references fail before remote mutation',
      () async {
    var calls = 0;
    final deployer = CatglobeDeployment((_) async {
      calls++;
      return 1;
    });
    await expectLater(deployer.deploy(config, 'test'), throwsStateError);
    expect(calls, 0);
    await File(p.join(temp.path, 'cgscript', 'A.cgs'))
        .writeAsString('new WorkflowScript("Missing");');
    await expectLater(deployer.deploy(config, 'test', includeBuild: false),
        throwsFormatException);
    expect(calls, 0);
  });

  for (final mode in ['test', 'production']) {
    for (final customAssets in [false, true]) {
      test(
          '$mode manifest start_url points to Dashboard (custom: $customAssets)',
          () async {
        final file = File(p.join(temp.path, 'build', 'web', 'manifest.json'));
        const original =
            '{"name":"App","start_url":".","display":"standalone"}';
        await file.writeAsString(original);
        final assets = FakeAssets();
        final client = FlatUploadClient();
        addTearDown(client.close);
        var id = 100;
        final result = await CatglobeDeployment((_) async => ++id,
                assets: customAssets ? assets : null,
                fileUploader: customAssets
                    ? null
                    : FileUploader(client, Uri.parse('https://example.com/'),
                        accessToken: () => 'token'))
            .deploy(config, mode);
        final dashboard = result['dashboardId'] as int;
        final bytes = customAssets
            ? assets.uploaded!['manifest.json']!
            : client.uploaded[
                FileUploader.storageName(dashboard, 'manifest.json')]!;
        expect(jsonDecode(utf8.decode(bytes)), {
          'name': 'App',
          'start_url':
              'https://example.com/ol/ReportModule/DashboardModule/DashboardViewer5.aspx?rid=$dashboard',
          'display': 'standalone',
        });
        expect(await file.readAsString(), original);
      });
    }
  }

  test('flat CgsFile build deploy uploads files and publishes mapped Dashboard',
      () async {
    final client = FlatUploadClient();
    final scripts = <String>[];
    var id = 100;
    final result = await CatglobeDeployment((s) async {
      scripts.add(s);
      return ++id;
    },
        fileUploader: FileUploader(client, Uri.parse('https://example.com/'),
            accessToken: () => 'token')).deploy(config, 'production');
    final dashboardId = result['dashboardId'] as int;
    expect(result['uploadedFiles'], ['catglobe-workflows.js', 'main.wasm']);
    expect(client.uploaded[FileUploader.storageName(dashboardId, 'main.wasm')],
        [0, 255, 128, 1]);
    expect(scripts.last, contains('Live portal'));
    expect(scripts.last, contains('/CgScript/File?file='));
    expect(scripts.last, contains('catglobeAssetUrls'));
    expect(
        await File(p.join(temp.path, 'build', 'web', 'index.html'))
            .readAsString(),
        '<html><head></head></html>');
  });

  test('production scripts use Live Script and reset run-as to zero', () async {
    final scripts = <String>[];
    await CatglobeDeployment((s) async {
      scripts.add(s);
      return 123;
    }).deploy(config, 'production', includeBuild: false);
    expect(scripts.first, contains('Live Script'));
    expect(scripts.last, contains('workflow.ImpersonatedUser = 0'));
    expect(scripts.last,
        contains('anonymousPermissions.Add(anonymousUser.ResourceId, "None")'));
  });

  test('asset URLs change with build contents and stay stable on redeploy',
      () async {
    final client = FlatUploadClient();
    addTearDown(client.close);
    final scripts = <String>[];
    final deployer = CatglobeDeployment((script) async {
      scripts.add(script);
      return 123;
    },
        fileUploader: FileUploader(client, Uri.parse('https://example.com/'),
            accessToken: () => 'token'));
    final bootstrap =
        File(p.join(temp.path, 'build', 'web', 'flutter_bootstrap.js'));
    await bootstrap.writeAsString('const version = 1;');
    final index = File(p.join(temp.path, 'build', 'web', 'index.html'));
    await index.writeAsString(
        '<html><head></head><body><script src="flutter_bootstrap.js"></script></body></html>');
    final first = await deployer.deploy(config, 'test');
    final hash = first['buildHash'] as String;
    expect(hash, matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(scripts.last, contains('v=$hash'));
    expect((await deployer.deploy(config, 'test'))['buildHash'], hash);
    await bootstrap.writeAsString('const version = 2;');
    final changed = await deployer.deploy(config, 'test');
    expect(changed['buildHash'], isNot(hash));
    expect(scripts.last, contains('v=${changed['buildHash']}'));
    expect(scripts.last, isNot(contains('v=$hash')));
    await index
        .writeAsString('<html><head></head><body>new layout</body></html>');
    expect((await deployer.deploy(config, 'test'))['buildHash'],
        isNot(changed['buildHash']));
  });

  test('public workflow grants anonymous Access while retaining run-as user',
      () async {
    await File(p.join(temp.path, 'cgscript', 'Public@456.public.cgs'))
        .writeAsString('return true;');
    final scripts = <String>[];
    var id = 100;
    final result = await CatglobeDeployment((s) async {
      scripts.add(s);
      return ++id;
    }).deploy(config, 'test', includeBuild: false);
    final workflowId = (result['workflowIds'] as Map<String, int>)['Public']!;
    final update = scripts.singleWhere((s) =>
        s.contains('workflow.CgScript') &&
        s.contains('workflow.ImpersonatedUser = 456'));
    expect(update, contains('User_getUserByUsername("anonymous")'));
    expect(
        update,
        contains(
            'if (anonymousUser == empty) throw "Anonymous user not found"'));
    expect(
        update,
        contains(
            'anonymousPermissions.Add(anonymousUser.ResourceId, "Access")'));
    expect(
        update,
        contains(
            'updateUserResourceIdPermission($workflowId, anonymousPermissions)'));
  });
}
