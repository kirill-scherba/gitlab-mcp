# DESIGN

## Overview

`gitlab-mcp` is a single-file Perl Model Context Protocol (MCP) server that exposes GitLab REST API operations as MCP tools.

## Architecture

```txt
MCP Client (AI)
       │
       │ JSON-RPC 2.0 over stdin/stdout
       ▼
┌──────────────┐
│ gitlab-mcp   │  Perl process
│              │
│ ┌──────────┐ │
│ │ MCP Loop │ │  while (<STDIN>) { decode → dispatch }
│ └────┬─────┘ │
│      │       │
│ ┌────▼─────┐ │
│ │ %tool_   │ │  registry of 20 tools
│ │ handlers │ │
│ └────┬─────┘ │
│      │       │
│ ┌────▼─────┐ │
│ │_gitlab_api│ │  curl wrapper for /api/v4
│ └────┬─────┘ │
│      │       │
│      ▼       │
┌──────────────┐
│ GitLab REST  │
│ API          │
└──────────────┘
```

## Components

### MCP Main Loop

- Reads one JSON-RPC message per line from stdin.
- Handles `initialize`, `ping`, `tools/list`, `tools/call`, `resources/list`, `prompts/list`.
- Logs to stderr; responses go to stdout.
- Tool errors are caught with `eval` and returned as JSON-RPC `-32603` errors.

### Tool Registry

All tools live in `%tool_handlers` mapping `name → { description, inputSchema, handler }`. Each handler is a Perl subroutine that validates required arguments, calls `_gitlab_api`, and returns a hashref.

### `_gitlab_api`

- Constructs URL: `$GITLAB_HOST/api/v4$path`.
- Adds `PRIVATE-TOKEN` header for authentication.
- Shells out to `curl` for HTTP requests.
- Captures HTTP code from `curl -w '%{http_code}'`.
- Decodes JSON response; surfaces GitLab `message`/`error` fields in error messages.

### URL Encoding

- `_gitlab_project_id` converts `namespace/project` to `namespace%2Fproject`.
- `_encode_file_path` URL-escapes file path segments for repository-files endpoints.
- `_uri_escape` escapes query parameter values.

## Design Decisions

1. **Single-file server** — same as `github-mcp.pl`; easy to deploy, no build step.
2. **No Safe sandbox** — direct Perl execution like `github-mcp.pl`; token is never exposed to generated/sandboxed code.
3. **curl over HTTP library** — keeps dependencies to core Perl modules.
4. **Configurable host** — supports gitlab.com and self-managed instances from the same binary.
5. **Auto-detect create vs update for files** — tries POST first, falls back to PUT on 4xx.

## Tool Categories

- Merge requests (7 tools)
- Issues (5 tools)
- Pipelines (4 tools)
- Projects (2 tools)
- Repository files (2 tools)

## Error Handling

- Missing required argument: `die "Missing required: X"`.
- Missing token: explicit JSON-RPC error with setup hint.
- API failure: GitLab error message propagated verbatim.
- Tool execution failure: caught by `eval` and returned as JSON-RPC error.

## Future Improvements

- Pagination support (Link header parsing).
- Caching of project path → numeric ID resolution.
- More pipeline/job operations.
- Group-level tools.
