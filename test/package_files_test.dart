import 'package:pana_workspace/pana_workspace.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  test('leaves out dot files, the lock file and overrides', () {
    final root = createTree({
      'pubspec.yaml': pubspec('a'),
      'pubspec.lock': '',
      'pubspec_overrides.yaml': '',
      '.dart_tool/package_config.json': '',
      '.htaccess': '',
      'lib/a.dart': '',
    });

    expect(listPackageFiles(root), ['.htaccess', 'lib/a.dart', 'pubspec.yaml']);
  });

  test('prefers .pubignore over .gitignore in the same directory', () {
    final root = createTree({
      'pubspec.yaml': pubspec('a'),
      '.gitignore': 'lib/generated.dart',
      '.pubignore': 'test/',
      'lib/generated.dart': '',
      'test/a_test.dart': '',
    });

    expect(listPackageFiles(root), ['lib/generated.dart', 'pubspec.yaml']);
  });

  test('applies the ignore files from the git root down to the package', () {
    final root = createTree({
      '.git/HEAD': '',
      '.gitignore': 'build/\n*.log',
      'packages/a/pubspec.yaml': pubspec('a'),
      'packages/a/build/output.txt': '',
      'packages/a/debug.log': '',
      'packages/a/lib/a.dart': '',
      'packages/a/lib/.gitignore': 'secret.dart',
      'packages/a/lib/secret.dart': '',
    });

    expect(listPackageFiles(p.join(root, 'packages', 'a')), [
      'lib/a.dart',
      'pubspec.yaml',
    ]);
  });
}
