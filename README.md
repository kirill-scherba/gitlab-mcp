# Gitlab MCP

Standalone MCP server for GitLab API -- merge requests, issues, pipelines, projects, and more.

Built with Perl 5, modeled after [kirill-scherba/github-mcp](https://github.com/kirill-scherba/github-mcp).

## Goals

- Merge request management (create, view, list, merge, approve)
- Issue management (create, view, list, comment)
- Pipeline operations (view, list, retry, cancel)
- Project operations (list, view, search)
- File operations (get, create, update via repository files API)
- Self-managed host support (like gitlab.dev.redpad.games)

## Status

Work in progress. See issue #1 for tasks.

## Setup

```shell
export GITLAB_TOKEN=glpat-your-token
export GITLAB_HOST=gitlab.dev.redpad.games # default: gitlab.com

// Run the MCP server
perl gitlab-mcp.pl
```

## Endpoints (REST)

- `HTTPREST GITLAB_HOST` - base url
- `HTTPREST GITLAB_API_UPRL (default: `/api/v4`)`

## Access Token

Use Personal Access Token with api_scope. Create one at Settings > Access Tokens.
