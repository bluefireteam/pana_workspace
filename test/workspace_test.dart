import 'package:pana_workspace/pana_workspace.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  test('loads the members that can be published', () {
    final root = createTree({
      'pubspec.yaml':
          'name: root\nworkspace:\n  - packages/a\n  - packages/b'
          '\n  - packages/private\n  - packages/unversioned',
      'packages/a/pubspec.yaml': pubspec('a', version: '1.2.3'),
      'packages/b/pubspec.yaml': pubspec('b'),
      'packages/private/pubspec.yaml': pubspec('private', publishable: false),
      'packages/unversioned/pubspec.yaml': pubspec(
        'unversioned',
        version: null,
      ),
    });

    final workspace = Workspace.load(root);

    expect(workspace.root, root);
    expect(workspace.packages.keys, unorderedEquals(['a', 'b']));
    expect(workspace.packages['a']!.version, '1.2.3');
    expect(workspace.packages['a']!.directory, p.join(root, 'packages', 'a'));
  });

  test('expands glob members and nested workspaces', () {
    final root = createTree({
      'pubspec.yaml': 'name: root\nworkspace:\n  - packages/*',
      'packages/a/pubspec.yaml': '${pubspec('a')}\nworkspace:\n  - example',
      'packages/a/example/pubspec.yaml': pubspec('a_example'),
      'packages/b/pubspec.yaml': pubspec('b'),
      'packages/not_a_package/README.md': '',
    });

    expect(
      Workspace.load(root).packages.keys,
      unorderedEquals(['a', 'a_example', 'b']),
    );
  });

  test('includes a root package that can be published', () {
    final root = createTree({
      'pubspec.yaml': '${pubspec('root')}\nworkspace:\n  - packages/a',
      'packages/a/pubspec.yaml': pubspec('a'),
    });

    expect(Workspace.load(root).packages.keys, unorderedEquals(['root', 'a']));
  });

  test('reads a pubspec without a workspace section as a single package', () {
    final root = createTree({'pubspec.yaml': pubspec('a', inWorkspace: false)});

    final workspace = Workspace.load(root);

    expect(workspace.root, root);
    expect(workspace.packages.keys, ['a']);
    expect(workspace.packages['a']!.directory, root);
  });

  test('leaves out a single package that cannot be published', () {
    final root = createTree({
      'pubspec.yaml': pubspec('a', publishable: false, inWorkspace: false),
    });

    expect(Workspace.load(root).packages, isEmpty);
  });

  test('finds the outermost workspace root', () {
    final root = createTree({
      'pubspec.yaml': 'name: root\nworkspace:\n  - packages/a',
      'packages/a/pubspec.yaml': '${pubspec('a')}\nworkspace:\n  - example',
      'packages/a/example/pubspec.yaml': pubspec('a_example'),
    });

    expect(Workspace.findRoot(p.join(root, 'packages', 'a', 'example')), root);
  });

  test('finds the nearest package outside of a workspace', () {
    final root = createTree({
      'pubspec.yaml': pubspec('a', inWorkspace: false),
      'lib/src/a.dart': '',
    });

    expect(Workspace.findRoot(p.join(root, 'lib', 'src')), root);
  });

  test('finds no root without a pubspec', () {
    final root = createTree({'README.md': ''});

    expect(Workspace.findRoot(root), isNull);
  });
}
