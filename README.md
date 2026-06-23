# gitlab-mcp

[![Perl](https://img.shields.io/badge/perl-5.40+-blue.svg)](https://www.perl.org/)
[![MCP](https://img.shields.io/badge/MCP-2024--11--05-green.svg)](https://modelcontextprotocol.io)

> **Standalone MCP server for GitLab API — 20 tools for merge requests, issues, pipelines, projects, and repository files.**

Modeled after [kirill-scherba/github-mcp](https://github.com/kirill-scherba/github-mcp). Uses direct `GITLAB_TOKEN` from environment — no sandbox limitations, full GitLab API access. Works with gitlab.com and self-managed instances (e.g. `gitlab.dev.redpad.games`).

## Features

- **20 GitLab API tools** — merge requests, issues, pipelines, projects, files
- **Direct authentication** — `GITLAB_TOKEN` from environment or `--env` argument
- **Self-managed GitLab** — configurable via `GITLAB_HOST`
- **Clean JSON-RPC 2.0** — MCP protocol over stdin/stdout
- **Structured logging** — all logs to stderr, stdout clean for JSON-RPC
- **Zero external dependencies** — `perl`, `JSON`, `MIME::Base64` (core), `IPC::Open3` (core), and `curl`

## Tools

| Tool | Description |
|------|-------------|
| `gitlab_project_list` | List accessible GitLab projects |
| `gitlab_project_get` | Get details of a GitLab project |
| `gitlab_issue_list` | List issues in a project with filters |
| `gitlab_issue_get` | Get issue details |
| `gitlab_issue_create` | Create a new issue |
| `gitlab_issue_update` | Update issue (title, body, state, labels, assignees) |
| `gitlab_issue_add_comment` | Add a comment to an issue |
| `gitlab_mr_list` | List merge requests with filters |
| `gitlab_mr_get` | Get merge request details and diff |
| `gitlab_mr_create` | Create a merge request |
| `gitlab_mr_merge` | Merge a merge request (with squash option) |
| `gitlab_mr_approve` | Approve a merge request |
| `gitlab_mr_add_comment` | Add a comment to a merge request |
| `gitlab_mr_list_comments` | List comments on a merge request |
| `gitlab_pipeline_list` | List CI/CD pipelines for a project |
| `gitlab_pipeline_get` | Get pipeline details |
| `gitlab_pipeline_retry` | Retry failed or canceled jobs in a pipeline |
| `gitlab_pipeline_cancel` | Cancel a running pipeline |
| `gitlab_file_get` | Get file contents from a repository |
| `gitlab_file_create_or_update` | Create or update a file via repository files API |

## Installation

### Prerequisites

```bash
# Perl modules (JSON and MIME::Base64 are core since 5.38+)
# IPC::Open3 is Perl core
# curl for GitLab API calls
sudo apt install curl   # Debian/Ubuntu
sudo pacman -S curl     # Arch Linux
```

All Perl modules used are part of the standard Perl core distribution.

### Setup

1. Clone the repository:

```bash
git clone https://github.com/kirill-scherba/gitlab-mcp.git
cd gitlab-mcp
chmod +x gitlab-mcp.pl
```

2. Set your GitLab token:

```bash
export GITLAB_TOKEN="glpat-..."
# Optional: for self-managed GitLab
export GITLAB_HOST="gitlab.dev.redpad.games"   # default: gitlab.com
```

3. Add to your MCP settings:

```json
{
  "mcpServers": {
    "gitlab-mcp": {
      "command": "perl",
      "args": ["/path/to/gitlab-mcp/gitlab-mcp.pl"],
      "env": {
        "GITLAB_TOKEN": "glpat-...",
        "GITLAB_HOST": "gitlab.dev.redpad.games"
      },
      "disabled": false,
      "autoApprove": []
    }
  }
}
```

## Usage

### List Projects

```json
{
  "membership": "true",
  "limit": 10
}
```

### Get Project

```json
{
  "project": "my-group/my-project"
}
```

### List Issues

```json
{
  "project": "my-group/my-project",
  "state": "opened",
  "labels": "bug,critical",
  "limit": 10
}
```

### Create Issue

```json
{
  "project": "my-group/my-project",
  "title": "Test task: MCP integration check",
  "description": "Created via gitlab-mcp MCP server",
  "labels": "test"
}
```

### Get File Contents

```json
{
  "project": "my-group/my-project",
  "file_path": "README.md",
  "ref": "main"
}
```

### Create or Update File

```json
{
  "project": "my-group/my-project",
  "file_path": "docs/example.md",
  "content": "# Example\n\nCreated via gitlab-mcp.",
  "commit_message": "docs: add example file",
  "branch": "main"
}
```

### List Merge Requests

```json
{
  "project": "my-group/my-project",
  "state": "opened",
  "limit": 10
}
```

### Create Merge Request

```json
{
  "project": "my-group/my-project",
  "title": "feat: add new feature",
  "source_branch": "feature/branch",
  "target_branch": "main",
  "description": "Implements the new feature."
}
```

### List Pipelines

```json
{
  "project": "my-group/my-project",
  "status": "running",
  "limit": 10
}
```

## Required Token Scopes

The GitLab token (`GITLAB_TOKEN`) needs the `api` scope for full functionality, or a combination of read/write scopes:

| Scope | Purpose |
|-------|---------|
| `api` | Full read + write access to all tools |
| `read_api` + `write_repository` | Read tools + file write operations |
| `read_api` | Read-only tools |

For self-managed instances, create a token at **Settings > Access Tokens**.

## Architecture

```txt
┌──────────────────────────────────────────────────────────┐
│                      MCP Client (AI)                     │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  │
│  │initialize│  │tools/list│  │tools/call│  │tools/call│  │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘  │
│       │             │             │             │         │
│       ▼             ▼             ▼             ▼         │
│              JSON-RPC 2.0 over stdin/stdout               │
└──────────────────────────┬────────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────┐
│                   gitlab-mcp (Perl)                      │
│                                                          │
│  ┌──────────┐   ┌──────────────┐   ┌──────────────────┐  │
│  │ MCP Main │──>│  Request     │──>│  GitLab REST API │  │
│  │ Loop     │   │  Dispatcher  │   │  via curl        │  │
│  │          │   │              │   │                  │  │
│  │ while    │   │  • 20 tools  │   │  + auth via      │  │
│  │ <STDIN>  │   │ • JSON-RPC   │   │  PRIVATE-TOKEN   │  │
│  │          │   │ • structured │   │  + configurable  │  │
│  │          │   │   responses  │   │    host          │  │
│  └──────────┘   └──────────────┘   └──────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

## Protocol

This server implements the **Model Context Protocol (MCP)** using **JSON-RPC 2.0** over stdin/stdout.

| Method | Description |
|--------|-------------|
| `initialize` | Handshake with protocol version and capabilities |
| `ping` | Health check |
| `tools/list` | Returns all 20 tool definitions with JSON Schema |
| `tools/call` | Executes a tool by name with provided arguments |

All logging goes to **stderr**, leaving **stdout** clean for JSON-RPC messages.

## Quick Test

```bash
cd /path/to/gitlab-mcp
export GITLAB_TOKEN="glpat-..."
export GITLAB_HOST="gitlab.dev.redpad.games"  # optional

# Test initialization
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}' | perl gitlab-mcp.pl 2>/dev/null

# Full test sequence
printf '{"jsonrpc":"2.0","id":1,"method":"initialize"}\n{"jsonrpc":"2.0","id":2,"method":"tools/list"}\n' | perl gitlab-mcp.pl 2>/dev/null
```

## Contributing

Contributions are welcome! Feel free to open issues or submit merge requests.

## License

MIT © Kirill Scherba

---

*Built with 🐪 — standalone GitLab MCP server in pure Perl.*
