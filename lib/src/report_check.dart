import 'package:pana/pana.dart';

/// Subsections that lose points when a dependency or the SDK publishes a new
/// release, so a release would otherwise start failing on the day it ships.
const defaultWarnOnlySubsections = {
  'All of the package dependencies are supported in the latest version',
  'Package supports latest stable Dart and Flutter SDKs',
};

final _subsectionHeader = RegExp(
  r'^### \[.\] (\d+)/(\d+) points: (.+)$',
  multiLine: true,
);
final _issue = RegExp(
  r'^<summary>\n([\s\S]*?)\n</summary>$|^\* (.+)$',
  multiLine: true,
);
final _markupLine = RegExp(r'^(\||\[`?[^\]]+`?\]: |\s*</?\w+[^>]*>)');
const _maxDetailLength = 1000;

/// A part of a pana report that lost points.
class Finding {
  /// Creates a finding for a subsection that lost points.
  Finding({
    required this.sectionTitle,
    required this.subsectionTitle,
    required this.grantedPoints,
    required this.maxPoints,
    required this.body,
    required this.warnOnly,
  });

  /// The title of the report section, such as "Provide documentation".
  final String sectionTitle;

  /// The title of the subsection that lost points, or [sectionTitle] when the
  /// lost points could not be traced to a subsection.
  final String subsectionTitle;

  /// The points the subsection scored.
  final int grantedPoints;

  /// The points the subsection can score.
  final int maxPoints;

  /// The Markdown pana wrote for the subsection.
  final String body;

  /// Whether the finding only warns instead of failing the check.
  final bool warnOnly;

  /// This finding, but only warning instead of failing the check.
  Finding asWarning() => Finding(
    sectionTitle: sectionTitle,
    subsectionTitle: subsectionTitle,
    grantedPoints: grantedPoints,
    maxPoints: maxPoints,
    body: body,
    warnOnly: true,
  );

  /// What pana says is missing, in plain text.
  String get detail {
    final reasons = _issue
        .allMatches(body)
        .map((match) => (match.group(1) ?? match.group(2)!).trim())
        .toList();
    return reasons.isEmpty ? _prose(body) : reasons.join('\n');
  }
}

/// The outcome of checking the pana report of one package.
class CheckResult {
  /// Creates the outcome of checking [package].
  CheckResult({
    required this.package,
    required this.summary,
    required this.findings,
    required this.missingWasm,
  });

  /// The package name.
  final String package;

  /// The pana summary that was checked.
  final Summary summary;

  /// The parts of the report that lost points.
  final List<Finding> findings;

  /// Whether the package supports the web without being WebAssembly ready,
  /// when the check requires it.
  final bool missingWasm;

  /// The findings that fail the check.
  Iterable<Finding> get errors =>
      findings.where((finding) => !finding.warnOnly);

  /// The findings that only warn.
  Iterable<Finding> get warnings =>
      findings.where((finding) => finding.warnOnly);

  /// Whether the package passes the check.
  bool get passed => summary.report != null && errors.isEmpty && !missingWasm;
}

/// Checks the pana [summary] of [package].
///
/// Every subsection that lost points becomes a [Finding], which only warns
/// when its title is in [warnOnlySubsections]. When [requireWasm] is set, a
/// package tagged `platform:web` must also be tagged `is:wasm-ready`. When it
/// is not set, the platform support subsection only warns when WebAssembly is
/// the only reason that it lost points.
CheckResult checkSummary(
  String package,
  Summary summary, {
  Set<String> warnOnlySubsections = defaultWarnOnlySubsections,
  bool requireWasm = true,
}) {
  final tags = summary.tags ?? const [];
  final notWasmReady =
      tags.contains('platform:web') && !tags.contains('is:wasm-ready');
  final onlyMissesWasm =
      notWasmReady && !tags.contains('is:darwin-legacy-native-build');
  return CheckResult(
    package: package,
    summary: summary,
    findings: [
      for (final section in summary.report?.sections ?? const <ReportSection>[])
        for (final finding in sectionFindings(section, warnOnlySubsections))
          if (!requireWasm && onlyMissesWasm && _isWasmPenalty(finding))
            finding.asWarning()
          else
            finding,
    ],
    missingWasm: requireWasm && notWasmReady,
  );
}

bool _isWasmPenalty(Finding finding) =>
    finding.sectionTitle == platformSupportSection &&
    finding.subsectionTitle.startsWith('Supports ') &&
    finding.maxPoints - finding.grantedPoints == wasmPenalty;

/// The title of the pana report section that scores the supported platforms.
const platformSupportSection = 'Platform support';

/// The points that pana takes from the platform support subsection when a
/// package supports the web but is not WebAssembly ready.
const wasmPenalty = 10;

/// Splits a report [section] into one finding per subsection that lost
/// points.
///
/// When the subsections do not explain all of the lost points, the whole
/// section is added as a finding that fails the check.
List<Finding> sectionFindings(
  ReportSection section,
  Set<String> warnOnlySubsections,
) {
  final lostPoints = section.maxPoints - section.grantedPoints;
  if (lostPoints == 0) {
    return const [];
  }
  final markdown = section.summary;
  final headers = _subsectionHeader.allMatches(markdown).toList();
  final findings = <Finding>[];
  for (final (index, header) in headers.indexed) {
    final granted = int.parse(header.group(1)!);
    final max = int.parse(header.group(2)!);
    if (granted == max) {
      continue;
    }
    final end = index + 1 < headers.length
        ? headers[index + 1].start
        : markdown.length;
    final subsectionTitle = header.group(3)!.trim();
    findings.add(
      Finding(
        sectionTitle: section.title,
        subsectionTitle: subsectionTitle,
        grantedPoints: granted,
        maxPoints: max,
        body: markdown.substring(header.end, end).trim(),
        warnOnly: warnOnlySubsections.contains(subsectionTitle),
      ),
    );
  }
  final explainedPoints = findings.fold(
    0,
    (sum, finding) => sum + finding.maxPoints - finding.grantedPoints,
  );
  if (explainedPoints < lostPoints) {
    findings.add(
      Finding(
        sectionTitle: section.title,
        subsectionTitle: section.title,
        grantedPoints: section.grantedPoints,
        maxPoints: section.maxPoints,
        body: markdown.trim(),
        warnOnly: false,
      ),
    );
  }
  return findings;
}

String _prose(String markdown) {
  final prose = markdown
      .split('\n')
      .where((line) => !_markupLine.hasMatch(line))
      .join('\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
  return prose.length <= _maxDetailLength
      ? prose
      : '${prose.substring(0, _maxDetailLength)}...';
}
