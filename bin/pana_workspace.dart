import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:pana_workspace/pana_workspace.dart';

Future<void> main(List<String> arguments) async {
  try {
    exitCode = await PanaWorkspaceRunner().run(arguments) ?? 0;
  } on UsageException catch (error) {
    stderr.writeln(error);
    exitCode = 64;
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 65;
  }
}
