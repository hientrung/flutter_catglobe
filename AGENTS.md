# Project instructions

## Dart and Flutter MCP

Before starting any Flutter or Dart task:

1. Check that the official `dart-flutter@dart-flutter` plugin and its Dart MCP tools are available in the current session.
2. Register this workspace with the MCP roots tool when available, then use MCP diagnostics and project inspection relevant to the task.
3. Prefer Dart MCP tools for analysis, formatting, fixes, package operations, tests, and running-app inspection when supported.
4. If MCP tools are unavailable, report this explicitly before using CLI fallbacks. Never claim MCP was used when only CLI commands ran.
5. Follow `.agent/rules/flutter-hot-reload.md` for edits to `lib/**/*.dart`. Only reload/restart an existing running app; if no app is running, report that reload was skipped.

The official plugin is installed in the local Codex account. Start a new Codex chat/session after installation to load its skills and MCP tools.
