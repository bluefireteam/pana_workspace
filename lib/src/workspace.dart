import 'dart:io';

import 'package:glob/glob.dart';
import 'package:glob/list_local_fs.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// A package of a pub workspace, or a single package, that can be published.
class WorkspacePackage {
  /// Creates a package from its [directory] and parsed [pubspec].
  WorkspacePackage({required this.directory, required this.pubspec});

  /// The absolute path of the package directory.
  final String directory;

  /// The package's pubspec, converted to JSON values.
  final Map<String, Object?> pubspec;

  /// The package name.
  String get name => pubspec['name']! as String;

  /// The package version.
  String get version => pubspec['version']! as String;
}

/// A pub workspace, or a single package, and the packages in it that can be
/// published.
class Workspace {
  /// Creates a workspace from its [root] and the [packages] in it.
  Workspace({required this.root, required this.packages});

  /// Reads the workspace whose root pubspec is in [root], including the
  /// members of nested workspaces.
  ///
  /// A root pubspec without a workspace section is read as a workspace with
  /// that single package. Members without a version or with
  /// `publish_to: none` are left out, since pub.dev never scores them.
  static Workspace load(String root) {
    final rootDirectory = p.normalize(p.absolute(root));
    final rootPubspec = _readPubspec(rootDirectory);
    final packages = <String, WorkspacePackage>{};
    void visit(String directory, Map<String, Object?> pubspec) {
      if (pubspec['publish_to'] != 'none' && pubspec['version'] != null) {
        final package = WorkspacePackage(
          directory: directory,
          pubspec: pubspec,
        );
        packages[package.name] = package;
      }
      for (final member in (pubspec['workspace'] as List? ?? const [])) {
        for (final memberDirectory in _expandMember(directory, '$member')) {
          visit(memberDirectory, _readPubspec(memberDirectory));
        }
      }
    }

    visit(rootDirectory, rootPubspec);
    return Workspace(root: rootDirectory, packages: packages);
  }

  /// Finds the root of the workspace that [directory] belongs to.
  ///
  /// Returns the outermost ancestor of [directory], [directory] included,
  /// whose pubspec has a workspace section. Without one, returns the nearest
  /// ancestor with a pubspec, so that a single package is its own workspace,
  /// or `null` if there is no pubspec at all.
  static String? findRoot(String directory) {
    String? workspaceRoot;
    String? packageRoot;
    var current = p.normalize(p.absolute(directory));
    while (true) {
      if (File(p.join(current, 'pubspec.yaml')).existsSync()) {
        packageRoot ??= current;
        if (_readPubspec(current)['workspace'] != null) {
          workspaceRoot = current;
        }
      }
      final parent = p.dirname(current);
      if (parent == current) {
        return workspaceRoot ?? packageRoot;
      }
      current = parent;
    }
  }

  /// Reads the pubspec in [directory] as JSON values.
  static Map<String, Object?> readPubspec(String directory) =>
      _readPubspec(directory);

  /// The absolute path of the workspace root.
  final String root;

  /// The packages that can be published, by name.
  final Map<String, WorkspacePackage> packages;
}

Iterable<String> _expandMember(String directory, String member) {
  if (!member.contains(RegExp(r'[*?\[{]'))) {
    return [p.normalize(p.join(directory, member))];
  }
  return Glob(member)
      .listSync(root: directory, followLinks: false)
      .whereType<Directory>()
      .where((match) => File(p.join(match.path, 'pubspec.yaml')).existsSync())
      .map((match) => p.normalize(match.path))
      .toList()
    ..sort();
}

Map<String, Object?> _readPubspec(String directory) {
  final file = File(p.join(directory, 'pubspec.yaml'));
  final yaml = loadYaml(file.readAsStringSync(), sourceUrl: file.uri);
  final json = _toJson(yaml);
  if (json is! Map<String, Object?>) {
    throw FormatException('${file.path} is not a YAML map.');
  }
  return json;
}

Object? _toJson(Object? yaml) => switch (yaml) {
  YamlMap() => {
    for (final entry in yaml.entries) '${entry.key}': _toJson(entry.value),
  },
  YamlList() => [for (final value in yaml) _toJson(value)],
  _ => yaml,
};
