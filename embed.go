// Copyright 2026 Kirill Scherba. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// Package gitlabmcp carries the Perl source of the server, so the binary and the script can never
// drift apart: both are built from this repository in one step.
package gitlabmcp

import _ "embed"

// Script is gitlab-mcp.pl, embedded at build time.
//
//go:embed gitlab-mcp.pl
var Script []byte
