@Tags(['pana'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('scores an unpublished sibling and fails on lost points', () async {
    final workspace = Directory.systemTemp.createTempSync(
      'pana_workspace_test.',
    );
    addTearDown(() => workspace.deleteSync(recursive: true));
    await Process.run('cp', [
      '-R',
      'test/fixtures/workspace/.',
      workspace.path,
    ]);
    final core = p.join(workspace.path, 'packages', 'greeting_core');
    Directory(p.join(core, 'example')).deleteSync(recursive: true);

    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'bin/pana_workspace.dart',
        '--directory',
        workspace.path,
        'check',
        '--no-dartdoc',
      ],
      environment: {'GITHUB_ACTIONS': 'false'},
    );
    final output = '${result.stdout}';

    expect(result.exitCode, 1, reason: '$output${result.stderr}');
    expect(
      output,
      contains(
        'pana_workspace_fixture scores the maximum in every pana section',
      ),
    );
    expect(
      output,
      contains(
        '[error] Provide documentation: Package has an example (0/10 points)',
      ),
    );
    expect(output, isNot(contains('pana_workspace_fixture_core scores')));
  });
}
