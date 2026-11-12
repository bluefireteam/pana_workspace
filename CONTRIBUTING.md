# Contributing

Pull request titles follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/),
since the squashed commits decide the next version and make up the changelog.

## Releasing

Releases are handled by [Melos](https://pub.dev/packages/melos), configured for a single package
in `pubspec.yaml`.

1. Run the "Prepare release" workflow. It bumps the version, writes the changelog and opens a
   `chore(release)` pull request.
2. Merge the pull request. The "Tag release" workflow tags the commit as `vX.Y.Z` and starts the
   "Publish package" workflow on the tag.
3. "Publish package" publishes to pub.dev, creates the GitHub release and moves the major version
   tag of the action, such as `v0`, to the release.
