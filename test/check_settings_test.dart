import 'package:pana_workspace/pana_workspace.dart';
import 'package:test/test.dart';

void main() {
  test('uses the defaults without a section', () {
    final settings = CheckSettings.fromSection(null);

    expect(settings.warnOnly, defaultWarnOnlySubsections);
    expect(settings.requireWasm, isTrue);
  });

  test('overrides the inherited settings that the section sets', () {
    final workspace = CheckSettings.fromSection({'require_wasm': false});
    final package = CheckSettings.fromSection({
      'warn_only': ['Package has an example'],
    }, inherited: workspace);

    expect(package.warnOnly, {'Package has an example'});
    expect(package.requireWasm, isFalse);
  });

  test('inherits every setting without a section', () {
    final workspace = CheckSettings.fromSection({
      'warn_only': ['Package has an example'],
      'require_wasm': false,
    });
    final package = CheckSettings.fromSection(null, inherited: workspace);

    expect(package.warnOnly, {'Package has an example'});
    expect(package.requireWasm, isFalse);
  });

  test('names the pubspec of an invalid section', () {
    expect(
      () => CheckSettings.fromSection({
        'require_wasm': 'no',
      }, source: 'packages/a/pubspec.yaml'),
      throwsA(
        isA<FormatException>()
            .having((error) => error.message, 'message', contains('true'))
            .having((error) => error.source, 'source', contains('packages/a')),
      ),
    );
  });
}
