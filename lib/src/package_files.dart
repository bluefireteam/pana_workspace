import 'dart:io';

import 'package:path/path.dart' as p;

import 'third_party/pub/ignore.dart';

const _basicIgnoreRules = [
  '.*',
  '!.htaccess',
  'pubspec.lock',
  '!pubspec.lock/',
  '/pubspec_overrides.yaml',
];

/// Lists the files that `dart pub publish` would put in the archive of the
/// package in [packageDirectory], relative to it and with `/` separators.
///
/// Follows the rules of pub: `.pubignore` takes precedence over `.gitignore`
/// in each directory, and inside a git repository the ignore files from the
/// repository root down to the package are taken into account.
List<String> listPackageFiles(String packageDirectory) {
  final packageRoot = p.normalize(p.absolute(packageDirectory));
  final root = _gitRoot(packageRoot) ?? packageRoot;
  final beneath = p.posix.joinAll(p.split(p.relative(packageRoot, from: root)));
  String resolve(String path) => p.joinAll([root, ...p.posix.split(path)]);
  final ignoreCase = Platform.isMacOS || Platform.isWindows;

  final files = Ignore.listFiles(
    beneath: beneath,
    listDir: (directory) => Directory(resolve(directory))
        .listSync(followLinks: false)
        .map(
          (entity) =>
              p.posix.joinAll(p.split(p.relative(entity.path, from: root))),
        ),
    ignoreForDir: (directory) {
      final pubIgnore = File(resolve('$directory/.pubignore'));
      final gitIgnore = File(resolve('$directory/.gitignore'));
      final ignoreFile = pubIgnore.existsSync()
          ? pubIgnore
          : gitIgnore.existsSync()
          ? gitIgnore
          : null;
      final rules = [
        if (directory == beneath) ..._basicIgnoreRules,
        if (ignoreFile != null) ignoreFile.readAsStringSync(),
      ];
      return rules.isEmpty ? null : Ignore(rules, ignoreCase: ignoreCase);
    },
    isDir: (path) => Directory(resolve(path)).existsSync(),
  );
  return [
    for (final file in files)
      beneath == '.' ? file : p.posix.relative(file, from: beneath),
  ]..sort();
}

String? _gitRoot(String directory) {
  var current = directory;
  while (true) {
    if (FileSystemEntity.typeSync(p.join(current, '.git')) !=
        FileSystemEntityType.notFound) {
      return current;
    }
    final parent = p.dirname(current);
    if (parent == current) {
      return null;
    }
    current = parent;
  }
}
