# CONTEXT

## Project

`gitlab-mcp` — standalone MCP server for GitLab API.

## Current State

- `gitlab-mcp.pl` implemented as a single-file Perl MCP server.
- 20 GitLab API tools registered and callable.
- README.md updated with setup, tool table, and usage examples.
- Memory Bank docs created.

## Recent Decisions

- Architecture mirrors `github-mcp.pl`: JSON-RPC 2.0 over stdin/stdout, tool registry (`%tool_handlers`), curl-based API helper.
- Auth via `GITLAB_TOKEN` env var or `--env gitlab_token=...` / `--env gitlab_token ...` arguments.
- Self-managed GitLab supported via `GITLAB_HOST` env var.
- GitLab API helper uses `PRIVATE-TOKEN` header and `/api/v4` base path.
- `curl` is invoked safely through `IPC::Open3` with a list of arguments (no shell interpolation).
- Project identifiers accept numeric IDs or `namespace/project` paths (slashes URL-encoded to `%2F`).
- File paths are URL-encoded when used in repository-files API endpoints.
- URL encoding is implemented locally; no external `URI::Escape` dependency.

## Operation Order

1. Load `GITLAB_TOKEN` and `GITLAB_HOST`.
2. Parse `--env key=value` arguments to override env vars.
3. Read JSON-RPC messages from stdin.
4. Dispatch `initialize`, `ping`, `tools/list`, `tools/call`.
5. For `tools/call`, look up handler in `%tool_handlers`, validate args, call GitLab REST API via curl.
6. Return JSON-encoded result wrapped in MCP `content` text object.

## Files

- `gitlab-mcp.pl` — main MCP server
- `README.md` — user-facing documentation
- `docs/CONTEXT.md` — this file
- `docs/DESIGN.md` — architecture and component relationships
- `docs/STATUS.md` — progress and known issues

## Known Issues

- No live integration tests against `gitlab.dev.redpad.games` performed yet due to no token in test environment.
- Error handling relies on GitLab API response bodies; some edge cases (e.g. HTML error pages) may produce JSON decode errors.
