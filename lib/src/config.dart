import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

class ProjectConfig {
  ProjectConfig(this.data) {
    // Callback is derived from the running server, never from stored config.
    data.remove('redirectUri');
    data.remove('scopes');
    data.remove('runEndpoint');
    data.remove('deployEndpoint');
    for (final key in ['id', 'name', 'projectPath', 'issuer']) {
      if (value(key).trim().isEmpty) throw FormatException('$key is required');
    }
    final issuer = Uri.parse(value('issuer'));
    if (issuer.scheme != 'https' || issuer.host.isEmpty) {
      throw const FormatException('Issuer must be an HTTPS URL');
    }
  }

  final Map<String, dynamic> data;
  String value(String key) => data[key]?.toString() ?? '';
  String get id => value('id');
  Map<String, dynamic> toJson() => data;
}

class ConfigStore {
  ConfigStore(this.file);
  final File file;

  static File defaultFile() {
    final env = Platform.environment;
    final base = Platform.isWindows
        ? env['APPDATA']
        : env['XDG_CONFIG_HOME'] ??
            (env['HOME'] == null ? null : p.join(env['HOME']!, '.config'));
    if (base == null) throw StateError('Cannot locate user config directory');
    return File(p.join(base, 'catglobe_dev', 'projects.json'));
  }

  Future<List<ProjectConfig>> read() async {
    if (!await file.exists()) return [];
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (json['version'] != 1)
      throw const FormatException('Unsupported config version');
    return (json['projects'] as List)
        .map((item) => ProjectConfig(Map<String, dynamic>.from(item as Map)))
        .toList();
  }

  Future<void> save(ProjectConfig config) => _update((configs) {
        configs.removeWhere((item) => item.id == config.id);
        configs.add(config);
      });

  Future<void> delete(String id) => _update((configs) {
        if (!configs.any((item) => item.id == id)) {
          throw StateError('Configuration not found');
        }
        configs.removeWhere((item) => item.id == id);
      });

  Future<void> _update(void Function(List<ProjectConfig>) update) async {
    // Lock a separate file so the lock remains valid across atomic replacement.
    await file.parent.create(recursive: true);
    final lock = await File('${file.path}.lock').open(mode: FileMode.append);
    await lock.lock(FileLock.blockingExclusive);
    try {
      final configs = await read();
      update(configs);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        const JsonEncoder.withIndent('  ')
            .convert({'version': 1, 'projects': configs}),
        flush: true,
      );
      await temporary.rename(file.path);
    } finally {
      await lock.unlock();
      await lock.close();
    }
  }
}
