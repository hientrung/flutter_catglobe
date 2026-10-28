import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

/// Validated settings for a local Catglobe project.
class ProjectConfig {
  /// Creates settings from the mutable [data] map.
  ///
  /// Removes obsolete endpoint, scope, and redirect overrides from [data].
  /// Throws [FormatException] for missing required values or a non-HTTPS issuer.
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

  /// The mutable settings backing this configuration.
  final Map<String, dynamic> data;

  /// Returns the string representation of [key], or an empty string if absent.
  String value(String key) => data[key]?.toString() ?? '';

  /// The identifier used to save and select this project.
  String get id => value('id');

  /// Returns the backing [data] map for JSON serialization.
  Map<String, dynamic> toJson() => data;
}

/// Persists project settings with file locking and atomic replacement.
class ConfigStore {
  /// Creates a configuration store backed by [file].
  ConfigStore(this.file);

  /// The JSON file containing versioned project settings.
  final File file;

  /// Returns the platform-specific user configuration file.
  ///
  /// Throws [StateError] if the user configuration directory cannot be located.
  static File defaultFile() {
    final env = Platform.environment;
    final base = Platform.isWindows
        ? env['APPDATA']
        : env['XDG_CONFIG_HOME'] ??
            (env['HOME'] == null ? null : p.join(env['HOME']!, '.config'));
    if (base == null) throw StateError('Cannot locate user config directory');
    return File(p.join(base, 'catglobe_dev', 'projects.json'));
  }

  /// Reads saved projects, returning an empty list if [file] does not exist.
  ///
  /// Throws [FormatException] for unsupported versions or invalid project settings.
  Future<List<ProjectConfig>> read() async {
    if (!await file.exists()) return [];
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (json['version'] != 1)
      throw const FormatException('Unsupported config version');
    return (json['projects'] as List)
        .map((item) => ProjectConfig(Map<String, dynamic>.from(item as Map)))
        .toList();
  }

  /// Adds [config], replacing any saved project with the same identifier.
  Future<void> save(ProjectConfig config) => _update((configs) {
        configs.removeWhere((item) => item.id == config.id);
        configs.add(config);
      });

  /// Deletes the saved project identified by [id].
  ///
  /// Throws [StateError] if the project does not exist.
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
