import 'dart:io';

import 'report_check.dart';

/// Writes the outcome of a check.
abstract class Reporter {
  /// Picks the GitHub Actions reporter when running in GitHub Actions and the
  /// plain text reporter otherwise.
  factory Reporter.forEnvironment({IOSink? out}) {
    final environment = Platform.environment;
    final sink = out ?? stdout;
    if (environment['GITHUB_ACTIONS'] == 'true') {
      return GitHubReporter(
        sink,
        stepSummaryPath: environment['GITHUB_STEP_SUMMARY'],
      );
    }
    return PlainReporter(sink);
  }

  /// Writes a problem that stopped [package] from being scored.
  void failure(String package, String message);

  /// Writes the outcome of checking one package.
  Future<void> result(CheckResult result);
}

/// Writes the outcome as plain text.
class PlainReporter implements Reporter {
  /// Creates a reporter that writes to [_out].
  PlainReporter(this._out);

  final IOSink _out;

  @override
  void failure(String package, String message) {
    _out.writeln('[error] $package: $message');
  }

  @override
  Future<void> result(CheckResult result) async {
    final report = result.summary.report!;
    _out.writeln(
      '${result.package}: ${report.grantedPoints}/${report.maxPoints} points',
    );
    for (final finding in result.findings) {
      final level = finding.warnOnly ? 'warning' : 'error';
      _out
        ..writeln(
          '[$level] ${finding.sectionTitle}: ${finding.subsectionTitle} '
          '(${finding.grantedPoints}/${finding.maxPoints} points)',
        )
        ..writeln(_indent(finding.detail));
    }
    if (result.missingWasm) {
      _out.writeln('[error] ${_wasmMessage(result.package)}');
    }
    if (result.passed) {
      _out.writeln(_passedMessage(result.package));
    }
  }
}

/// Writes the outcome as GitHub Actions annotations, log groups and a step
/// summary.
class GitHubReporter implements Reporter {
  /// Creates a reporter that writes workflow commands to [_out] and the
  /// job summary to [stepSummaryPath].
  GitHubReporter(this._out, {this.stepSummaryPath});

  final IOSink _out;

  /// The file that GitHub Actions renders as the job summary.
  final String? stepSummaryPath;

  final _stopToken = 'pana-workspace-${DateTime.now().microsecondsSinceEpoch}';

  @override
  void failure(String package, String message) {
    _out.writeln(
      '::error title=${escapeProperty('$package: pana')}::'
      '${escapeData(message)}',
    );
  }

  @override
  Future<void> result(CheckResult result) async {
    for (final finding in result.findings) {
      final command = finding.warnOnly ? 'warning' : 'error';
      final title = escapeProperty(
        '${result.package}: ${finding.sectionTitle}',
      );
      final message = [
        '${finding.subsectionTitle}: '
            '${finding.grantedPoints}/${finding.maxPoints} points.',
        finding.detail,
        if (finding.warnOnly) 'This only warns.',
      ].join('\n');
      _out
        ..writeln('::$command title=$title::${escapeData(message)}')
        ..writeln('::group::${escapeData(finding.subsectionTitle)}')
        ..writeln('::stop-commands::$_stopToken')
        ..writeln(finding.body)
        ..writeln('::$_stopToken::')
        ..writeln('::endgroup::');
    }
    if (result.missingWasm) {
      _out.writeln(
        '::error title=${escapeProperty('${result.package}: WebAssembly')}::'
        '${escapeData(_wasmMessage(result.package))}',
      );
    }
    if (result.passed) {
      _out.writeln(_passedMessage(result.package));
    }
    final path = stepSummaryPath;
    if (path != null) {
      await File(
        path,
      ).writeAsString(stepSummary(result), mode: FileMode.append);
    }
  }

  /// Renders [result] as the Markdown of a job summary.
  static String stepSummary(CheckResult result) {
    final report = result.summary.report!;
    final summary = StringBuffer()
      ..writeln('### pana: ${result.package}')
      ..writeln()
      ..writeln('Total: ${report.grantedPoints}/${report.maxPoints} points')
      ..writeln()
      ..writeln('| Section | Points | Status |')
      ..writeln('| --- | --- | --- |');
    for (final section in report.sections) {
      summary.writeln(
        '| ${section.title} | ${section.grantedPoints}/${section.maxPoints} '
        '| ${section.status.name} |',
      );
    }
    summary
      ..writeln()
      ..writeln('Tags: ${(result.summary.tags ?? const []).join(', ')}')
      ..writeln();
    for (final (heading, findings) in [
      ('Lost points', result.errors),
      ('Lost points that only warn', result.warnings),
    ]) {
      if (findings.isEmpty) {
        continue;
      }
      summary
        ..writeln('#### $heading')
        ..writeln();
      for (final finding in findings) {
        summary
          ..writeln('<details>')
          ..writeln(
            '<summary>${finding.sectionTitle}: ${finding.subsectionTitle} '
            '(${finding.grantedPoints}/${finding.maxPoints})</summary>',
          )
          ..writeln()
          ..writeln(finding.body)
          ..writeln()
          ..writeln('</details>')
          ..writeln();
      }
    }
    return summary.toString();
  }
}

/// Escapes the message of a GitHub Actions workflow command.
String escapeData(String value) => value
    .replaceAll('%', '%25')
    .replaceAll('\r', '%0D')
    .replaceAll('\n', '%0A');

/// Escapes a property of a GitHub Actions workflow command.
String escapeProperty(String value) =>
    escapeData(value).replaceAll(':', '%3A').replaceAll(',', '%2C');

String _wasmMessage(String package) =>
    '$package supports the web (platform:web) but is not WebAssembly ready. '
    'See https://dart.dev/web/wasm';

String _passedMessage(String package) =>
    '$package scores the maximum in every pana section that fails the check.';

String _indent(String text) =>
    text.split('\n').map((line) => '    $line').join('\n');
