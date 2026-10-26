# catglobe_dev

Development-only Dart package for Flutter projects. Provides a local web console,
shared project configuration, and Authorization Code + PKCE S256 authentication.
No Flutter runtime dependency is needed for this host-side tool.

## Run

Add to your Flutter project's `pubspec.yaml`:

```yaml
dev_dependencies:
  catglobe_dev: ^0.1.0
```

```sh
flutter pub get
dart run catglobe_dev --port 5000
```

For development inside this repository: `dart pub get`, then
`dart run bin/catglobe_dev.dart`. Options: `--no-open`, `--port`, `--data`.
Stop with Ctrl+C. The server binds only to `127.0.0.1`.
The console URL uses `http://localhost:5000` by default. Override the port with
`--port 6000` to use `http://localhost:6000`. Redirect URI is derived from the
running port, shown read-only in the console, and is not saved in project configs.

The hosted dependency above becomes available after publication. Until then,
use `catglobe_dev: {path: /absolute/path/to/this/repository}` under
`dev_dependencies`. The repository directory does not need to match the package
name. The old package/library/executable name `flutter_catglobe` is replaced by
`catglobe_dev`; import `package:catglobe_dev/catglobe_dev.dart`.
The shared config directory is now `catglobe_dev`; if you have existing data,
copy the old `flutter_catglobe/projects.json` file to the new directory while
the server is stopped, or point `--data` at the existing file.

## Publish to pub.dev

See [PUBLISHING.md](PUBLISHING.md) for preparation, verification, publication,
and subsequent release steps. Version 0.1.0 is a development preview with the
remote API limitations described below. No package has been published by this
repository setup.

## Configuration and authentication

Open the local web console, create a config, save, then select it in the dropdown
to use it immediately. Create is always available; Edit, Delete and Connection
and execution appear only when a config is selected. Deleting the active config
clears the selection and local authentication. Selecting the empty option also
clears selection and authentication.
Every startup requires a selection. Configs are shared across projects in:

- Windows: `%APPDATA%/catglobe_dev/projects.json`
- Linux: `$XDG_CONFIG_HOME/catglobe_dev/projects.json` (default `~/.config`)
- macOS: `~/.config/catglobe_dev/projects.json`

Use absolute `projectPath`, relative `scriptDirectory` (e.g. `cgscript`) and
`buildDirectory` (e.g. `build/web`).
New configurations default the project folder to `Directory.current.path`, the
directory where you run the CLI, and the project name to that folder's name.
Editing a config keeps its saved name and project folder.
Set issuer to the exact discovery issuer, including trailing slash:
`https://voxmeter.catglobe.com/`.
The client ID can remain empty until you register a public client with PKCE S256.
Register `http://localhost:5000/auth/callback` as its redirect URI, matching your port.
For example, `--port 6000` requires registering
`http://localhost:6000/auth/callback`. Old saved redirect URI values are ignored.
No client secret is used. Scopes are fixed to
`email profile roles openid offline_access`; the client must
be granted these permissions. Access tokens remain in memory, expire according to
the provider response, and are cleared when switching/editing config or logging out.
Log in again on expiry. Refresh tokens are not persisted or used in this version.
Local logout does not end the identity provider's browser session.

This version uses OAuth access tokens to authorize API calls. It does not expose
an authenticated user identity or validate/use ID tokens as identity assertions.

## Remote execution / deployment contract (provisional)

CGScript execution always uses `/api/cgscript/dynamicrun` on the issuer server;
the endpoint and scopes cannot be edited. Old config overrides are ignored.
Deployment also runs CGScript through the same `dynamicrun` endpoint to upload
and write files. There is no separate remote deployment endpoint or setting.
The dynamicrun request uses the payload below. CGScript upload/write functions
and response handling still require server integration verification.
POST redirects are disabled.

Execution POST payload:

```json
{"ScriptName":"FlutterApp","Script":"contents entered in the textarea","Parameter":[]}
```

The console provides an inline CGScript textarea for testing arbitrary scripts;
its content is saved automatically in browser localStorage and restored on the
next visit using the same browser and localhost port, including after login.
`/api/run` accepts `{ "script": "..." }`, rather than a file path.
Configuration editing is shown only for New/Edit and hidden after saving.
A single Login/Logout button reflects the current authentication state.

Build deployment has explicit `test` (review) and `production` (customer release)
modes. The local deploy request includes `kind: "build"` and the selected `mode`;
the server rejects missing or unknown modes.

`DeploymentScriptBuilder` receives the config, deployment kind, mode, and local files
as `{path, contentBase64}` records. It must generate the actual CGScript that
uploads/writes these files under the configured root folder. That script is sent
using the same request shape as ordinary execution. Until the Catglobe functions
and syntax are supplied, the default CLI reports that this implementation is
missing rather than sending an invented script or a raw file manifest to dynamicrun.

The UI exposes Test and Production build deployment for this integration. The
builder must implement the actual server destination/release behavior for each
mode; selecting a mode alone does not implement server-side review or promotion.
With a
deployment script builder supplied, files are read recursively,
symlinks are skipped, and deployments are capped at 50 MiB before base64 encoding.
Run `flutter build web` in the consumer project first: this tool uploads existing
build output and does not invoke a build. Remote responses are shown in the UI.
There is no automatic rollback or server-side atomic deployment guarantee.

## Checks

```sh
dart analyze
dart test
```

Tests cover the RFC PKCE vector, state binding/replay protection, config updates,
and local server startup/request protection. Real authentication and deployment
require a registered client and the confirmed remote API.
