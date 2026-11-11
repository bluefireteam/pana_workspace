# pana_workspace examples

Score every package of the workspace that can be published:

```sh
dart pub global activate pana_workspace
cd my_workspace
pana_workspace check
```

Score one package from a GitHub Actions workflow:

```yaml
- uses: actions/checkout@v7
- uses: subosito/flutter-action@v2
- uses: bluefireteam/pana_workspace@v0
  with:
    packages: my_package
```

Use the package server and the report check from Dart:

```dart
import 'package:pana_workspace/pana_workspace.dart';

Future<void> main() async {
  final workspace = Workspace.load(Workspace.findRoot('.')!);
  final server = await PackageServer.start(workspace);
  print('pana --hosted-url ${server.url} <package> <version>');
}
```

The [fixture workspace](https://github.com/bluefireteam/pana_workspace/tree/main/test/fixtures/workspace)
that the tests score has a package that depends on an unpublished version of its sibling.
