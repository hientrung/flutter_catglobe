import 'dart:io';
import 'package:catglobe/catglobe.dart';

// For normal use, run `dart run catglobe` instead.
Future<void> main() async {
  final server = DevelopmentServer(ConfigStore(ConfigStore.defaultFile()));
  await server.start();
  stdout.writeln('Select or create a project at ${server.url}');
  await ProcessSignal.sigint.watch().first;
  await server.close();
}
