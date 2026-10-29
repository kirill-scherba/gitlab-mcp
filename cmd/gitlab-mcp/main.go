// Copyright 2026 Kirill Scherba. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// gitlab-mcp as a single binary.
//
// The server itself is a Perl program (gitlab-mcp.pl, embedded below); this wrapper runs it on a Perl
// interpreter compiled into the executable, so a machine needs nothing installed - no Perl, no CPAN,
// no configuration of an interpreter. The same source builds for Linux and Windows, and both read
// their settings from the environment the MCP host passes to this process.
//
// The sandbox is deliberate: the guest sees exactly the environment it was given, only the filesystem
// it needs (the real one, because the server writes request bodies to temp files), and may spawn only
// curl - the network is reached through that subprocess, never from the interpreter's own sockets.
package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	perl "github.com/goccy/go-perl"
	"github.com/goccy/go-perl/fs"

	gitlabmcp "github.com/kirill-scherba/gitlab-mcp"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "gitlab-mcp: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	// The guest works on the real filesystem, exactly like `perl gitlab-mcp.pl` would: the server asks
	// curl to write responses to files, and those files have to be the same ones both sides see. A
	// private filesystem here would mean curl writes to the host while the script reads its own memory
	// (curl exit 23 / empty responses, found the hard way).
	stdlib, err := perl.ExtractStdlib()
	if err != nil {
		return err
	}
	defer os.RemoveAll(stdlib)

	scriptPath, err := os.CreateTemp("", "gitlab-mcp-*.pl")
	if err != nil {
		return err
	}
	if _, err := scriptPath.Write(gitlabmcp.Script); err != nil {
		scriptPath.Close()
		return err
	}
	if err := scriptPath.Close(); err != nil {
		return err
	}
	defer os.Remove(scriptPath.Name())

	p, err := perl.New(perl.Config{
		FS:        fs.NewHostFS(),
		StdlibDir: stdlib,
		Env:       os.Environ(), // whatever the MCP host passed: tokens never live on the host system
		Stdin:     os.Stdin,
		Stdout:    os.Stdout,
		Stderr:    os.Stderr,
		Exec: func(path string, argv []string) bool {
			switch strings.ToLower(filepath.Base(path)) {
			case "curl", "curl.exe":
				return true
			}
			fmt.Fprintf(os.Stderr, "gitlab-mcp: refusing to run %q\n", path)
			return false
		},
		Dial:    func(network, host, ip string, port int) bool { return false },
		Resolve: func(host string) bool { return false },
	})
	if err != nil {
		return err
	}
	defer p.Close()

	return p.RunFile(context.Background(), scriptPath.Name(), nil, os.Args[1:])
}
