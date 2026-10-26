import 'dart:async';
import 'dart:io';
import 'package:args/args.dart';
import 'config.dart';
import 'server.dart';

Future<int> runCli(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('port', defaultsTo: '5000')
    ..addOption('data', help: 'Override shared projects JSON path')
    ..addFlag('open', defaultsTo: true, help: 'Open the management web page')
    ..addFlag('help', abbr: 'h', negatable: false);
  late ArgResults options;
  try {
    options = parser.parse(arguments);
    if (options.rest.isNotEmpty)
      throw const FormatException('Unexpected arguments');
    if (options.flag('help')) {
      stdout.writeln(parser.usage);
      return 0;
    }
    final port = int.tryParse(options.option('port')!);
    if (port == null || port < 1 || port > 65535)
      throw const FormatException('Invalid port');
    final server = DevelopmentServer(ConfigStore(options.option('data') == null
        ? ConfigStore.defaultFile()
        : File(options.option('data')!)));
    await server.start(port: port);
    stdout.writeln('Catglobe development tools: ${server.url}');
    stdout.writeln('Redirect URI: ${server.url.resolve('/auth/callback')}');
    final done = Completer<void>();
    final signal = ProcessSignal.sigint.watch().listen((_) {
      if (!done.isCompleted) done.complete();
    });
    try {
      if (options.flag('open')) {
        try {
          final uri = server.url.toString();
          if (Platform.isWindows) {
            await Process.run('rundll32', ['url.dll,FileProtocolHandler', uri]);
          } else {
            await Process.run(Platform.isMacOS ? 'open' : 'xdg-open', [uri]);
          }
        } catch (_) {
          stderr.writeln('Open the URL above in your browser.');
        }
      }
      await done.future;
    } finally {
      await signal.cancel();
      await server.close();
    }
    return 0;
  } on FormatException catch (error) {
    stderr.writeln('${error.message}\n${parser.usage}');
    return 64;
  } catch (error) {
    stderr.writeln(error);
    return 70;
  }
}
