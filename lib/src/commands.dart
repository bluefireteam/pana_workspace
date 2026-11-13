import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:logging/logging.dart';
import 'package:pana/pana.dart';
import 'package:path/path.dart' as p;

import 'package_server.dart';
import 'report_check.dart';
import 'reporter.dart';
import 'workspace.dart';

/// The `pana_workspace` command line tool.
class PanaWorkspaceRunner extends CommandRunner<int> {
  /// Creates the runner with every command.
  PanaWorkspaceRunner()
    : super(
        'pana_workspace',
        'Scores a package, or the packages of a pub workspace, with pana '
            'before they are published, resolving sibling packages from the '
            'checkout.',
      ) {
    argParser.addOption(
      'directory',
      abbr: 'C',
      help: 'A directory inside the workspace or the package.',
      defaultsTo: '.',
    );
    addCommand(CheckCommand());
    addCommand(ServeCommand());
    addCommand(ListCommand());
  }
}

abstract class _WorkspaceCommand extends Command<int> {
  Workspace loadWorkspace() {
    final directory = globalResults!.option('directory')!;
    final root = Workspace.findRoot(directory);
    if (root == null) {
      throw UsageException(
        'No pubspec.yaml was found in $directory or any of its parents.',
        usage,
      );
    }
    return Workspace.load(root);
  }

  Uri upstream() {
    final value = argResults!.option('upstream');
    return value == null ? PackageServer.defaultUpstream() : Uri.parse(value);
  }

  void addUpstreamOption() {
    argParser.addOption(
      'upstream',
      help:
          'The hosted repository to forward every other request to. Defaults '
          'to PUB_HOSTED_URL, or https://pub.dev when it is not set.',
    );
  }
}

/// Scores packages with pana and fails when one loses points.
class CheckCommand extends _WorkspaceCommand {
  /// Creates the command and its options.
  CheckCommand() {
    addUpstreamOption();
    argParser
      ..addMultiOption(
        'warn-only',
        splitCommas: false,
        help:
            'The title of a subsection that only warns when it loses points. '
            'Replaces the defaults and the warn_only settings of the '
            'pubspecs.',
      )
      ..addFlag(
        'require-wasm',
        defaultsTo: null,
        help:
            'Fail a package that supports the web but is not WebAssembly '
            'ready. On unless the pubspec of the workspace or of the package '
            'sets require_wasm: false.',
      )
      ..addFlag(
        'dartdoc',
        defaultsTo: true,
        help:
            'Run dartdoc, which scores the dartdoc coverage of the public API.',
      )
      ..addOption(
        'json-output',
        valueHelp: 'directory',
        help: 'Write the pana report of each package to <package>.json here.',
      )
      ..addFlag('verbose', abbr: 'v', help: 'Print the pana log.');
  }

  @override
  String get name => 'check';

  @override
  String get description =>
      'Scores packages with pana and fails when one loses points. Scores '
      'every package that can be published when no package is given.';

  @override
  String get invocation => '${runner!.executableName} check [<package>...]';

  @override
  Future<int> run() async {
    final arguments = argResults!;
    final workspace = loadWorkspace();
    final workspaceSettings = CheckSettings.fromPubspec(workspace.root);
    CheckSettings settingsOf(WorkspacePackage package) {
      final settings = package.directory == workspace.root
          ? workspaceSettings
          : CheckSettings.fromSection(
              package.pubspec['pana_workspace'],
              inherited: workspaceSettings,
              source: p.join(package.directory, 'pubspec.yaml'),
            );
      return CheckSettings(
        warnOnly: arguments.wasParsed('warn-only')
            ? arguments.multiOption('warn-only').toSet()
            : settings.warnOnly,
        requireWasm: arguments.wasParsed('require-wasm')
            ? arguments.flag('require-wasm')
            : settings.requireWasm,
      );
    }

    final names = arguments.rest.isEmpty
        ? (workspace.packages.keys.toList()..sort())
        : arguments.rest;
    for (final name in names) {
      if (!workspace.packages.containsKey(name)) {
        throw UsageException(
          '$name is not a package in the workspace that can be published. '
          'The packages are: ${workspace.packages.keys.join(', ')}.',
          usage,
        );
      }
    }
    final settingsByName = {
      for (final name in names) name: settingsOf(workspace.packages[name]!),
    };

    final logs = Logger.root.onRecord.listen((record) {
      if (arguments.flag('verbose') || record.level >= Level.SEVERE) {
        stderr.writeln('[${record.level.name}] ${record.message}');
      }
    });
    Logger.root.level = Level.ALL;
    final reporter = Reporter.forEnvironment();
    final server = await PackageServer.start(workspace, upstream: upstream());
    final temporary = await Directory.systemTemp.createTemp('pana_workspace.');
    final temporaryPath = await temporary.resolveSymbolicLinks();
    final jsonOutput = arguments.option('json-output');
    var passed = true;
    try {
      final pubCache = await Directory(
        p.join(temporaryPath, 'pub-cache'),
      ).create();
      final analyzer = PackageAnalyzer(
        await ToolEnvironment.create(
          pubCacheDir: pubCache.path,
          pubHostedUrl: server.url.toString(),
        ),
      );
      for (final name in names) {
        final package = workspace.packages[name]!;
        stdout.writeln('Scoring ${package.name} ${package.version}.');
        final Summary summary;
        try {
          summary = await analyzer.inspectPackage(
            package.name,
            version: package.version,
            options: InspectOptions(
              pubHostedUrl: server.url.toString(),
              dartdocOutputDir: arguments.flag('dartdoc')
                  ? p.join(temporaryPath, 'doc', name)
                  : null,
              resourcesOutputDir: p.join(temporaryPath, 'resources', name),
            ),
          );
        } on Object catch (error) {
          reporter.failure(name, 'pana failed: $error');
          passed = false;
          continue;
        }
        if (jsonOutput != null) {
          await _writeJson(jsonOutput, name, summary);
        }
        if (summary.report == null) {
          reporter.failure(
            name,
            'pana did not produce a report. ${summary.errorMessage ?? ''}',
          );
          passed = false;
          continue;
        }
        final settings = settingsByName[name]!;
        final result = checkSummary(
          name,
          summary,
          warnOnlySubsections: settings.warnOnly,
          requireWasm: settings.requireWasm,
        );
        await reporter.result(result);
        passed &= result.passed;
      }
    } finally {
      await server.close();
      await logs.cancel();
      await temporary.delete(recursive: true);
    }
    return passed ? 0 : 1;
  }

  Future<void> _writeJson(
    String directory,
    String name,
    Summary summary,
  ) async {
    final json = summary.toJson()
      ..['scores'] = {
        'grantedPoints': summary.report?.grantedPoints,
        'maxPoints': summary.report?.maxPoints,
      };
    final file = File(p.join(directory, '$name.json'));
    await file.parent.create(recursive: true);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(json));
  }
}

/// Serves the workspace packages until the process is stopped.
class ServeCommand extends _WorkspaceCommand {
  /// Creates the command and its options.
  ServeCommand() {
    addUpstreamOption();
  }

  @override
  String get name => 'serve';

  @override
  String get description =>
      'Serves the packages of the workspace, or the single package, from the '
      'checkout and forwards every other request upstream. Pass the printed '
      'URL to `pana --hosted-url`.';

  @override
  Future<int> run() async {
    final server = await PackageServer.start(
      loadWorkspace(),
      upstream: upstream(),
    );
    stdout.writeln('Serving ${server.url}');
    await ProcessSignal.sigint.watch().first;
    await server.close();
    return 0;
  }
}

/// Prints the packages of the workspace, or the single package, that can be
/// published.
class ListCommand extends _WorkspaceCommand {
  /// Creates the command and its options.
  ListCommand() {
    argParser.addFlag('json', help: 'Print the names as a JSON list.');
  }

  @override
  String get name => 'list';

  @override
  String get description =>
      'Prints the packages of the workspace, or the single package, that can '
      'be published.';

  @override
  Future<int> run() async {
    final names = loadWorkspace().packages.keys.toList()..sort();
    stdout.writeln(
      argResults!.flag('json') ? jsonEncode(names) : names.join('\n'),
    );
    return 0;
  }
}

/// The `pana_workspace` section of a pubspec.
///
/// The root pubspec of the workspace sets it for every package, and the
/// pubspec of a package overrides it for that package.
class CheckSettings {
  /// Creates settings with the subsections that only warn and whether
  /// WebAssembly readiness is required.
  CheckSettings({required this.warnOnly, required this.requireWasm});

  /// The settings that apply when no pubspec has a `pana_workspace` section.
  static final defaults = CheckSettings(
    warnOnly: defaultWarnOnlySubsections,
    requireWasm: true,
  );

  /// Reads the settings of the pubspec in [directory].
  ///
  /// ```yaml
  /// pana_workspace:
  ///   warn_only:
  ///     - Package supports latest stable Dart and Flutter SDKs
  ///   require_wasm: false
  /// ```
  ///
  /// The settings that the pubspec leaves out are taken from [inherited].
  factory CheckSettings.fromPubspec(
    String directory, {
    CheckSettings? inherited,
  }) => CheckSettings.fromSection(
    Workspace.readPubspec(directory)['pana_workspace'],
    inherited: inherited,
    source: p.join(directory, 'pubspec.yaml'),
  );

  /// Reads the `pana_workspace` [section] of a pubspec, which is `null` when
  /// the pubspec does not have one.
  ///
  /// The settings that the section leaves out are taken from [inherited], and
  /// [source] names the pubspec in the error when the section is invalid.
  factory CheckSettings.fromSection(
    Object? section, {
    CheckSettings? inherited,
    String? source,
  }) {
    final parent = inherited ?? defaults;
    if (section == null) {
      return parent;
    }
    if (section is! Map<String, Object?>) {
      throw FormatException('pana_workspace must be a map.', source);
    }
    final warnOnly = section['warn_only'];
    final requireWasm = section['require_wasm'];
    if (warnOnly != null && warnOnly is! List) {
      throw FormatException(
        'pana_workspace.warn_only must be a list of subsection titles.',
        source,
      );
    }
    if (requireWasm != null && requireWasm is! bool) {
      throw FormatException(
        'pana_workspace.require_wasm must be true or false.',
        source,
      );
    }
    return CheckSettings(
      warnOnly: warnOnly == null
          ? parent.warnOnly
          : {for (final title in warnOnly as List) '$title'},
      requireWasm: requireWasm as bool? ?? parent.requireWasm,
    );
  }

  /// The titles of the subsections that only warn.
  final Set<String> warnOnly;

  /// Whether a package that supports the web must be WebAssembly ready.
  final bool requireWasm;
}
