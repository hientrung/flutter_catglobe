import 'dart:io';
import 'package:catglobe_dev/catglobe_dev.dart';

// For normal use, run `dart run catglobe_dev` instead.
Future<void> main() async {
  final server = DevelopmentServer(ConfigStore(ConfigStore.defaultFile()));
  await server.start();
  stdout.writeln('Select or create a project at ${server.url}');
  await ProcessSignal.sigint.watch().first;
  await server.close();
}
