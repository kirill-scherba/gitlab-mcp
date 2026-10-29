# Third-party notices

`gitlab-mcp` is one file to the person who runs it: a single executable. Inside it are three
different works under three different licenses, and this file says which is which, because the
executable is redistributed and the licenses require their notices to travel with it.

| Component | Version | License | Copyright |
|---|---|---|---|
| `gitlab-mcp.pl` + Go wrapper (this repository) | see tags | BSD 3-Clause (`LICENSE`) | 2026 Kirill Scherba |
| `github.com/goccy/perlwasm2go` — Perl 5 interpreter as machine-translated Go | v0.2.2 | Artistic License 1.0 **or** GPL-1.0-or-later (Perl's own dual license) | 1993–2025 Larry Wall and others; 2026 Masaaki Goshima |
| `github.com/goccy/go-perl` — the Go API around the translated interpreter | v0.2.0 | MIT | 2026 Masaaki Goshima |
| Perl 5 standard library (`JSON::PP`, `MIME::Base64`, `IPC::Open3`, …) | 5.42.x | same as Perl 5 | Larry Wall and others |

## Perl 5: which branch of the dual license this distribution uses

Perl 5 — and therefore `perlwasm2go`, which is a derivative work of it — may be used under
*either* the GNU General Public License (version 1 or later) *or* the Artistic License.
This project distributes under the **Artistic License 1.0**. Full texts, copied verbatim from the
pinned Perl 5 sources, are in `LICENSES/Artistic-1.0.txt` and `LICENSES/GPL-1.0.txt`.

Artistic License 1.0 permits distributing the Package "in aggregate with other (possibly
commercial) programs as part of a larger (possibly commercial) software distribution", and that is
exactly what this repository does: it ships an unmodified interpreter inside its own program.
Nothing in this repository adds a restriction to the interpreter beyond the Artistic terms, and
Perl is not sold as a separate item.

What that means in practice:

- **The Perl parts are not ours.** They are not relicensed under BSD, and the BSD license in
  `LICENSE` applies only to the server code written here (see the note at the end of `LICENSE`).
- **The interpreter is unmodified.** No Perl source file in `perlwasm2go` is patched by this
  project, so the "modified Package" clauses of the Artistic License do not apply. The machine
  translation itself, with its sources, is published by its author at
  https://github.com/goccy/perlwasm2go (v0.2.2, verified by `perl_wasm2go.sha256` in that module).
- **Your Perl code and its output stay yours.** As the `perlwasm2go` documentation states: Perl
  scripts run on the embedded interpreter, and their output, do not fall under the Package's
  copyright. That is what keeps `gitlab-mcp.pl` a BSD-licensed work of its own, and it is why an
  application that merely runs this server is not affected by Perl's license at all.
- **Redistribution**: whoever passes the executable on should keep this file and `LICENSES/`
  next to it. The release archives built by CI contain them.

## Trademark

GitLab is a trademark of GitLab Inc. This server is an independent, unofficial client of the
GitLab API. It is not produced, endorsed, or supported by GitLab Inc.
