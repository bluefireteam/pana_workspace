# pana_workspace

Scores the packages of a [pub workspace](https://dart.dev/tools/pub/workspaces) with
[pana](https://pub.dev/packages/pana) before they are published, and fails when one loses pub.dev
points.

Running pana on a workspace package does not work well on its own. pana removes the workspace
resolution and resolves every dependency from pub.dev, so a package that depends on a version of a
sibling package that is not published yet fails to resolve, and loses most of its points. That is
the normal state of a release pull request, where the versions are bumped before anything is
published.

pana_workspace starts a local package server that serves the packages of the workspace from the
checkout and forwards every other request to pub.dev. pana then scores each package from the same
archive that `dart pub publish` would upload, and the sibling packages resolve to the versions in
the checkout.

## Command line

```sh
dart pub global activate pana_workspace
```

Run the commands anywhere inside the workspace, or point at it with `--directory`.

```sh
# Score every package that can be published, and fail when one loses points.
pana_workspace check

# Score some of them.
pana_workspace check my_package my_other_package

# Print the packages that can be published, for example to build a CI matrix.
pana_workspace list --json

# Serve the workspace packages and pass the printed URL to pana yourself.
pana_workspace serve
pana --hosted-url <printed url> my_package 1.2.3
```

`check` reports every pana subsection that lost points, with what pana says is missing, and exits
with 1 when one of them fails the check. Under GitHub Actions it writes annotations, log groups and
a job summary.

Packages without a `version` and packages with `publish_to: none` are left out, since pub.dev never
scores them.

## Configuration

Two subsections only warn by default, because they lose points on the day a dependency or the SDK
publishes a new release, without any change to the package:

- All of the package dependencies are supported in the latest version
- Package supports latest stable Dart and Flutter SDKs

A package that supports the web also has to be WebAssembly ready by default.

Both can be changed in the root `pubspec.yaml` of the workspace:

```yaml
pana_workspace:
  warn_only:
    - Package supports latest stable Dart and Flutter SDKs
  require_wasm: false
```

`--warn-only` and `--[no-]require-wasm` override the pubspec.

## GitHub Action

The action needs Dart, and Flutter when the workspace has Flutter packages.

```yaml
jobs:
  pana:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: subosito/flutter-action@v2
      - uses: bluefireteam/pana_workspace@v0
```

| Input               | Default | Description                                                |
| ------------------- | ------- | ---------------------------------------------------------- |
| `packages`          | all     | The packages to score, separated by spaces or new lines.   |
| `working-directory` | `.`     | A directory inside the workspace.                          |
| `warn-only`         |         | Subsection titles that only warn, one per line.            |
| `dartdoc`           | `true`  | Whether to run dartdoc, which scores the dartdoc coverage. |
| `json-output`       |         | A directory to write the pana report of each package to.   |

Scoring a package takes a minute or two, so a large workspace is faster with one job per package:

```yaml
jobs:
  packages:
    runs-on: ubuntu-latest
    outputs:
      packages: ${{ steps.list.outputs.packages }}
    steps:
      - uses: actions/checkout@v7
      - uses: dart-lang/setup-dart@v1
      - run: dart pub global activate pana_workspace
      - id: list
        run: echo "packages=$(dart pub global run pana_workspace list --json)" >> "$GITHUB_OUTPUT"

  pana:
    needs: packages
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        package: ${{ fromJSON(needs.packages.outputs.packages) }}
    steps:
      - uses: actions/checkout@v7
      - uses: subosito/flutter-action@v2
      - uses: bluefireteam/pana_workspace@v0
        with:
          packages: ${{ matrix.package }}
```

## How the archive is built

The archive of each package holds the files that `dart pub publish` would upload. The rules are
the ones of pub: `.pubignore` takes precedence over `.gitignore` in each directory, the ignore files
from the git root down to the package apply, and dot files, `pubspec.lock` and
`pubspec_overrides.yaml` are left out. The ignore matching is pub's own implementation.
