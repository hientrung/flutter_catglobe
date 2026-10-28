# catglobe

Dart package for Catglobe Flutter clients, local development, and deployment. Provides a local web console,
shared project configuration, and Authorization Code + PKCE S256 authentication.
No Flutter runtime dependency is needed for this host-side tool.

## Run

Add to your Flutter project's `pubspec.yaml`:

```yaml
dev_dependencies:
  catglobe: ^0.1.0
```

```sh
flutter pub get
dart run catglobe --port 5000
```

For development inside this repository: `dart pub get`, then
`dart run bin/catglobe.dart`. Options: `--no-open`, `--port`, `--data`.
Stop with Ctrl+C. The server binds only to `127.0.0.1`.
The console URL uses `http://localhost:5000` by default. Override the port with
`--port 6000` to use `http://localhost:6000`. Redirect URI is derived from the
running port, shown read-only in the console, and is not saved in project configs.

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

- Windows: `%APPDATA%/catglobe/projects.json`
- Linux: `$XDG_CONFIG_HOME/catglobe/projects.json` (default `~/.config`)
- macOS: `~/.config/catglobe/projects.json`

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
`http://localhost:6000/auth/callback`.
No client secret is used. Scopes are fixed to
`openid offline_access`; the client must
be granted these permissions. Access tokens remain in memory, expire according to
the provider response, and are cleared when switching/editing config or logging out.
Refresh tokens returned with `offline_access` are kept only in memory. Before
console execution and each upload, tokens expiring within 30 seconds are renewed
at the discovered token endpoint. Rotated refresh tokens replace the previous
value; concurrent requests share one refresh. Logout/config changes discard both
tokens. If refresh permission is revoked or no refresh token was issued, log in
again. An in-flight refresh cannot restore a logged-out session.
Local logout does not end the identity provider's browser session.

This version uses OAuth access tokens to authorize API calls. It does not expose
an authenticated user identity or validate/use ID tokens as identity assertions.

## Remote execution / deployment contract (provisional)

CGScript execution always uses `/api/cgscript/dynamicrun` on the issuer server;
the endpoint and scopes cannot be edited.
Deployment creates and updates resources through `dynamicrun`; build assets
are uploaded separately through `/api/files/upload/{saveAs}`.
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

### Run a local workflow from Flutter

After selecting a project in the management console, call
`POST http://localhost:5000/api/cgscript/run/Folder/Name` with a JSON body.
The name is relative to `scriptDirectory`, without `.cgs`, `@userId` or `.public`.
URL-encode each name segment when it contains spaces or non-ASCII characters.
Set `Content-Type: application/json` and `Authorization: Bearer <access_token>`
using the Flutter app's Catglobe access token. The local API forwards this token
to Catglobe for authentication and execution. Alternatively, send `X-Cg-Token`
using `devApiToken` from `GET /api/configs` to run with the console login session.
The Flutter app owns renewal of its caller-supplied token: the local API does not
have that caller's refresh token. Explicit Bearer tokens always take precedence.
Flutter Web preflights and requests from localhost/loopback origins are supported.

```dart
final response = await http.post(
  Uri.parse('http://localhost:5000/api/cgscript/run/Folder/Name'),
  headers: {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer $accessToken',
  },
  body: jsonEncode({'customerId': 123}),
);
```

The local bridge forwards the JSON body directly as dynamicrun's `Parameter`.
Both Catglobe endpoints wrap this value once, so the script receives it at
`Workflow_getParameters()[0]`. With `?expandParameters=true`, send an array of
positional arguments instead. Local responses preserve Catglobe's HTTP status
and complete `{result, error}` JSON envelope, including script errors returned
with HTTP 200. Source files are reloaded on each call.

### One Flutter call for debug and deployed apps

For runtime use, add `catglobe` under `dependencies` and import the web-safe
client library (the management/CLI library imports `dart:io`):

```dart
import 'package:flutter/foundation.dart';
import 'package:catglobe/catglobe_client.dart';

final workflows = CatglobeWorkflowClient(
  debug: kDebugMode,
  // Set this if the production API is on another origin; defaults to Uri.base.
  // issuer: Uri.parse('https://your-site.catglobe.com/'),
  // Optional: omit in debug to use the local server login session.
  // accessToken: () => authentication.getValidAccessToken(),
);

final result = await workflows.run('Folder/Name', parameter: {'customerId': 123});
// workflows.close() when the owning service is disposed.
```

The named `parameter` argument is optional and defaults to `null`. Omitted or
null values are sent as an empty JSON array (`[]`), for example
`workflows.run('GetUserName')`.

`authentication.getValidAccessToken()` above represents your app's existing
authentication provider. The callback is invoked for every call. In debug, the
client POSTs to `http://localhost:5000/api/cgscript/run/Folder/Name`. Outside debug,
it reads `globalThis.catglobeWorkflowIds` injected into the deployed Dashboard and
POSTs to `/api/cgscript/run/<id>` on the issuer. An explicit `workflowIds` map can
also be supplied. Release mode fails if a mapping is missing; it never falls back
to a local filename. Both modes send the identical JSON body and decode the same
Catglobe envelope into the return value or `CgScriptException`.

When the deployed web app uses the issuer's same-origin browser login session,
the access-token callback may be omitted online. In debug, omitting `accessToken`
automatically obtains the development API token and uses the selected project's
current local server login session, including token refresh. Select a project
and log in through the local management console first. The Catglobe token stays
on the server. An explicitly configured callback returning an empty token raises
an error instead of switching accounts.

`ScriptRewriter` is the shared rule pipeline with explicit `local` and `deploy`
modes. Local mode recursively replaces `new WorkflowScript("Folder/A")` with
`new WorkflowScript("escaped source of A", false)`. It rejects missing files,
duplicate logical names and cycles with the full dependency chain before making
the remote call. Shared dependencies without cycles are allowed. Deployment mode
uses resource IDs, so deployed workflows can still have cyclic references.
Comments, literals and constructors already using numeric IDs or inline code are
preserved. Expansion is limited to 100 nesting levels and 10 MiB of source.
Local API execution uses the caller's access token or, when using `X-Cg-Token`,
the selected project's server login session; filename impersonation/public settings
apply when creating deployed Workflow resources.

The UI textarea also passes through `ScriptRewriter` in local mode, so test code
can call `new WorkflowScript("Folder/Name")` directly. It uses the console login
session, with the same missing-reference and cycle checks as the local API.

Build deployment has explicit `test` (review) and `production` (customer release)
modes. The local deploy request includes `kind: "build"` and the selected `mode`;
the server rejects missing or unknown modes.

Before local execution or deployment, standalone conditional directives select
environment-specific CGScript:

```text
#IF dev
DebugLog("Local or test deployment");
#ENDIF
#IF production
DebugLog("Production deployment");
#ENDIF
```

Local execution and test deployment accept `test`, `dev`, and `development`.
Production deployment accepts `prod`, `production`, `live`, and `release`.
Directive keywords and mode values are case-insensitive. Matching blocks keep
their code and remove the directive lines; nonmatching blocks are removed while
code outside them remains. Nested blocks are supported. Directives inside
comments or string literals are preserved. Unknown modes or unbalanced blocks
raise an error. Filtering happens before workflow reference resolution.

Deployed workflow source starts with an English `//` notice containing the UTC
deployment timestamp and warning that manual edits will be overwritten on the
next deployment. Local execution does not add this notice.

The built-in `CatglobeDeployment` orchestrator requires a positive `rootFolderId`.
It scans `.cgs` files recursively from `scriptDirectory` (default `cgscript`).
`Folder/Name@123.public.cgs` becomes workflow `Folder_Name` directly in the mode folder,
with lookup key `Folder/Name` and impersonated user 123. Both suffixes are
optional, but `.public` requires a positive `@userId`. Duplicate lookup keys and
missing named dependencies fail before any remote writes. Flattened name
collisions (for example, `Folder/Name.cgs` and `Folder_Name.cgs`) also fail
before any remote writes.

Test workflows live directly in `Test Script`; production workflows directly in
`Live Script`. Local subdirectories become underscore-separated name prefixes;
no matching remote subfolders are created.
Resources are reused by exact name, type and direct parent, preserving their IDs
on repeated deployments. The orchestrator first reserves all workflows, then
replaces `new WorkflowScript("Folder/Name")` references with numeric IDs and
updates code and impersonation. Cyclic references work. Comments, string literals
and existing numeric references are preserved. References use paths relative to
the script root, without `.cgs` or metadata suffixes.

Build deployment creates/reuses `Test portal` or `Live portal` under the root.
The Dashboard layout receives `index.html` with
`globalThis.catglobeWorkflowIds` injected before Flutter bootstrap and a base URL
for its assets. The same map is uploaded as `catglobe-workflows.js`. Consumers
must read this JavaScript global when resolving workflow names in deployed apps.
All remaining build files retain their relative paths and exact bytes and are
passed to the uploader together with the Dashboard ID.

For `.public` workflows, deployment looks up `User_getUserByUsername("anonymous")`
and grants that user's resource ID `Access` on the Workflow through
`updateUserResourceIdPermission`. Missing anonymous users cause public deployment
to fail. The `@userId` remains the workflow's impersonated user and is independent
of the anonymous account. Without `.public`, deployment sets the anonymous user's
direct permission to `None` when that account exists; inherited/group permissions
are not changed. The deploying account needs FullControl on the Workflow to
update its permissions.

The stock CLI uses `CgsFileUploader` and flat asset mapping. Optional custom
`DeploymentAssets` implementations can override anonymous permission scripts
and upload using a directory URL via `DevelopmentServer(deploymentAssets: ...)`.
Script-only deployment is available through `CatglobeDeployment.deploy` with
`includeBuild: false`.

A custom `DeploymentScriptBuilder` can be supplied for custom sites;
when supplied it bypasses the built-in orchestrator.

`CgsFileUploader` implements the site's `POST /api/files/upload/{saveAs}` contract:
the body contains raw file bytes with `Content-Type: application/octet-stream`,
and query parameters `overWrite=true` and `isTemp=false` select permanent storage.
It sends the access token as a Bearer header, disables redirects and checks both
HTTP status and the JSON `success`, `filename`, `isTemp` and `size` response. Filenames contain the Dashboard
ID, SHA-256 of the complete relative path, and the original extension, avoiding
collisions when the server sanitizes directory separators. Bytes are unchanged.
Its `upload` returns a map of local paths to `/CgScript/File?file=...` download URLs.
Empty files are supported by the raw-stream API.

The default build deployment uploads through `CgsFileUploader`. It rewrites HTML
asset attributes, CSS `url(...)` references and static/dynamic literal module
imports in JavaScript. Before bootstrap, the Dashboard installs a map from a
virtual build directory to actual query URLs. The bridge translates Flutter URL
construction, fetch/XHR calls and dynamically assigned script/media URLs,
including paths resolved relative to an uploaded module. No server folder route
is required. External absolute URLs pass through. Binary files remain unchanged;
only uploaded copies of text files are transformed. Local build files are untouched.

Tests cover the mapping bridge and a simulated full deployment; no live Catglobe
upload or full Flutter browser smoke test has been performed. Service-worker
offline caching and arbitrary third-party worker loaders are not verified.

Files are read recursively with symlinks skipped and each input directory capped
at 50 MiB. Run `flutter build web` in the consumer project first; this tool uploads
existing output. Deployment makes multiple remote calls and has no automatic
rollback; an interrupted deployment can leave partially updated resources.

## Checks

```sh
dart analyze
dart test
```

Tests cover the RFC PKCE vector, state binding/replay protection, config updates,
and local server startup/request protection. Real authentication and deployment
require a registered client and the confirmed remote API.
