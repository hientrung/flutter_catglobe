import 'dart:io';
import 'package:catglobe_dev/src/cli.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runCli(arguments);
}
