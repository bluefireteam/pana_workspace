import 'dart:io';

import 'package:pana/pana.dart';
import 'package:pana_workspace/pana_workspace.dart';
import 'package:test/test.dart';

ReportSection _section({
  required String title,
  required int grantedPoints,
  required int maxPoints,
  String summary = '',
}) => ReportSection(
  id: title,
  title: title,
  grantedPoints: grantedPoints,
  maxPoints: maxPoints,
  status: grantedPoints == maxPoints
      ? ReportStatus.passed
      : ReportStatus.failed,
  summary: summary,
);

Summary _summary(
  List<ReportSection> sections, {
  List<String> tags = const [],
}) => Summary(
  createdAt: DateTime.utc(2026),
  runtimeInfo: PanaRuntimeInfo(panaVersion: '0.23.19', sdkVersion: '3.13.0'),
  tags: tags,
  report: Report(sections: sections),
);

const _documentation = '''
### [*] 10/10 points: 20% or more of the public API has dartdoc comments

### [x] 0/10 points: Package has an example

<details>
<summary>
No example found.
</summary>

See the package layout guidelines.
</details>
''';

const _dependencies = '''
### [*] 10/10 points: All of its dependencies are compatible

### [x] 0/10 points: All of the package dependencies are supported in the latest version

* Sorry, your package does not support the latest major version of http.
''';

void main() {
  test('passes a package that scores the maximum', () {
    final result = checkSummary(
      'a',
      _summary([_section(title: 'Docs', grantedPoints: 20, maxPoints: 20)]),
    );

    expect(result.findings, isEmpty);
    expect(result.passed, isTrue);
  });

  test('reports each subsection that lost points with its reason', () {
    final result = checkSummary(
      'a',
      _summary([
        _section(
          title: 'Provide documentation',
          grantedPoints: 10,
          maxPoints: 20,
          summary: _documentation,
        ),
      ]),
    );

    final finding = result.findings.single;
    expect(finding.sectionTitle, 'Provide documentation');
    expect(finding.subsectionTitle, 'Package has an example');
    expect(finding.grantedPoints, 0);
    expect(finding.maxPoints, 10);
    expect(finding.detail, 'No example found.');
    expect(finding.warnOnly, isFalse);
    expect(result.passed, isFalse);
  });

  test('only warns for the warn-only subsections', () {
    final result = checkSummary(
      'a',
      _summary([
        _section(
          title: 'Support up-to-date dependencies',
          grantedPoints: 10,
          maxPoints: 20,
          summary: _dependencies,
        ),
      ]),
    );

    expect(result.warnings.single.detail, contains('latest major version'));
    expect(result.errors, isEmpty);
    expect(result.passed, isTrue);
  });

  test('fails on a warn-only subsection when it is not configured', () {
    final result = checkSummary(
      'a',
      _summary([
        _section(
          title: 'Support up-to-date dependencies',
          grantedPoints: 10,
          maxPoints: 20,
          summary: _dependencies,
        ),
      ]),
      warnOnlySubsections: const {},
    );

    expect(result.passed, isFalse);
  });

  test('reports the whole section when subsections do not explain it', () {
    final result = checkSummary(
      'a',
      _summary([
        _section(
          title: 'Pass static analysis',
          grantedPoints: 0,
          maxPoints: 50,
          summary: 'Failed to resolve dependencies.',
        ),
      ]),
    );

    final finding = result.findings.single;
    expect(finding.subsectionTitle, 'Pass static analysis');
    expect(finding.detail, 'Failed to resolve dependencies.');
    expect(result.passed, isFalse);
  });

  test('requires WebAssembly readiness from a web package', () {
    final summary = _summary(const [], tags: ['platform:web']);

    expect(checkSummary('a', summary).missingWasm, isTrue);
    expect(checkSummary('a', summary).passed, isFalse);
    expect(checkSummary('a', summary, requireWasm: false).passed, isTrue);
    expect(
      checkSummary(
        'a',
        _summary(const [], tags: ['platform:web', 'is:wasm-ready']),
      ).passed,
      isTrue,
    );
  });

  test('escapes workflow command values', () {
    expect(escapeData('50% done\r\nnext'), '50%25 done%0D%0Anext');
    expect(escapeProperty('a: b, c'), 'a%3A b%2C c');
  });

  test('writes annotations that GitHub cannot mistake for commands', () async {
    final file = File(
      '${Directory.systemTemp.createTempSync('pana_workspace_test.').path}/out',
    );
    addTearDown(() => file.parent.deleteSync(recursive: true));
    final sink = file.openWrite();
    final result = checkSummary(
      'a',
      _summary([
        _section(
          title: 'Provide documentation',
          grantedPoints: 10,
          maxPoints: 20,
          summary: '$_documentation\n::error::injected',
        ),
      ]),
    );

    await GitHubReporter(sink).result(result);
    await sink.close();
    final lines = file.readAsLinesSync();

    expect(
      lines.first,
      '::error title=a%3A Provide documentation::Package has an example: '
      '0/10 points.%0ANo example found.',
    );
    final stop = lines.indexWhere((line) => line.startsWith('::stop-commands'));
    final resume = lines.indexOf('::${lines[stop].split('::').last}::');
    expect(lines.indexOf('::error::injected'), inInclusiveRange(stop, resume));
  });
}
