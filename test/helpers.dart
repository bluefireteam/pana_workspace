import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Creates a temporary directory with [files], keyed by their path relative
/// to it, and deletes it after the test.
String createTree(Map<String, String> files) {
  final root = Directory.systemTemp.createTempSync('pana_workspace_test.');
  addTearDown(() => root.deleteSync(recursive: true));
  for (final MapEntry(key: path, value: contents) in files.entries) {
    File(p.join(root.path, path))
      ..createSync(recursive: true)
      ..writeAsStringSync(contents);
  }
  return root.resolveSymbolicLinksSync();
}

/// A minimal pubspec for a package called [name].
String pubspec(
  String name, {
  String? version = '1.0.0',
  Map<String, String> dependencies = const {},
  bool publishable = true,
}) => [
  'name: $name',
  if (version != null) 'version: $version',
  if (!publishable) 'publish_to: none',
  'environment:',
  '  sdk: ^3.11.0',
  'resolution: workspace',
  if (dependencies.isNotEmpty) 'dependencies:',
  for (final MapEntry(:key, :value) in dependencies.entries) '  $key: $value',
].join('\n');
