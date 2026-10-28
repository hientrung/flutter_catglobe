# Publishing catglobe

Official reference: https://dart.dev/tools/pub/publishing

## 1. Prepare the release

- Sign in to pub.dev with the Google account that will own the package.
- Check https://pub.dev/packages/catglobe for name availability. If it already
  exists, you need publishing permission for it; a local dry run does not reserve
  or guarantee ownership of the name.
- Review the included BSD 3-Clause LICENSE and confirm that it matches the
  owner's licensing intent and that you can redistribute all included code.
  Adjust the copyright holder if appropriate before the first release.
- Source repository and issue tracker are configured in `pubspec.yaml` for
  https://github.com/hientrung/flutter_catglobe. Verify repository visibility and
  access before publishing; optionally add `homepage` and `documentation`.
- Review version 0.1.0 in `pubspec.yaml` and the first release entry in CHANGELOG.md.
- The remote execution/deployment API is provisional. For an end-to-end usable
  Catglobe release, implement the confirmed API and test it with a registered
  public PKCE client. Otherwise retain the preview limitations in the release.

## 2. Verify locally

Run from the package root with a supported Dart SDK:


```sh
dart pub get
dart format --output=none --set-exit-if-changed lib bin test example
dart analyze
dart test
dart run bin/catglobe.dart --help
dart pub publish --dry-run
```

Review every warning and the exact archive file list. `.pubignore` excludes
workspace instructions, build/cache outputs and lockfiles. Keep client secrets,
tokens and real user configuration outside the package tree; inspect the archive
list for any local files you added. A dry run validates packaging but does not
upload, reserve a name or validate real server behavior.

Also test from a separate Flutter consumer project using a path dependency:

```yaml
dev_dependencies:
  catglobe:
    path: /absolute/path/to/this/repository
```

```sh
flutter pub get
dart run catglobe --port 5000
```

Verify web config editing/selection, a registered
`http://localhost:5000/auth/callback` redirect URI and PKCE login.
For remote operations, use the confirmed API and a test server/project.
Use `dev_dependencies` for CLI-only tooling. When the Flutter app imports
`package:catglobe/client.dart`, add `catglobe` to `dependencies`.

## 3. Publish manually

When the archive and release contents are ready:

```sh
dart pub publish
```

Follow the CLI authentication link and upload confirmation. The first publisher
must be authorized to own the package name. For a verified organization publisher,
follow the current pub.dev publisher setup/transfer instructions in the official
reference. Publication is persistent; use a new version for later changes.

After upload, inspect https://pub.dev/packages/catglobe and test installation
in a clean Flutter project:

```sh
flutter pub add --dev catglobe
dart run catglobe --help
```

Optionally install the executable globally:

```sh
dart pub global activate catglobe
catglobe --help
```

Ensure the Dart pub cache `bin` directory is on PATH for the global command.

## 4. Later versions

Update the version and CHANGELOG, repeat checks and consumer verification, then
publish. Each published version is unique and cannot be overwritten. Commit
and tag releases in your source repository when it is available. Automated
publishing can be configured after the initial manual publication using the
official pub.dev instructions.
