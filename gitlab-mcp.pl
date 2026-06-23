#!/usr/bin/env perl
# =============================================================================
# gitlab-mcp - Standalone MCP server for GitLab API tools
#
# Repository: github.com/kirill-scherba/gitlab-mcp
#
# Features:
#   - 20 GitLab API tools (merge requests, issues, pipelines, projects, files)
#   - Direct GITLAB_TOKEN from environment or --env argument
#   - Configurable GITLAB_HOST for self-managed GitLab instances
#   - JSON-RPC 2.0 over stdin/stdout (MCP protocol)
#   - Detailed logging to stderr
# =============================================================================

use strict;
use warnings;
use utf8;
use JSON;
use POSIX qw(strftime);
use MIME::Base64;
use URI::Escape;

use English '-no_match_vars';

# ---------------------------------------------------------------------------
# UTF-8 encoding
# ---------------------------------------------------------------------------
binmode(STDIN,  ":utf8");
binmode(STDOUT, ":utf8");
binmode(STDERR, ":utf8");

# ---------------------------------------------------------------------------
# Parse --env key=value arguments
# ---------------------------------------------------------------------------
my %env_args;
for my $arg (@ARGV) {
    if ($arg =~ /^--env\s+([^=]+)=(.*)$/) {
        $env_args{$1} = $2;
    }
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
my $GITLAB_TOKEN = $env_args{gitlab_token} // $ENV{GITLAB_TOKEN} // '';
my $GITLAB_HOST  = $env_args{gitlab_host} // $ENV{GITLAB_HOST}  // 'https://gitlab.com';

# Ensure scheme is present
$GITLAB_HOST = "https://$GITLAB_HOST" unless $GITLAB_HOST =~ /^https?:\/\//;

log_message("INFO", "GITLAB_TOKEN " . ($GITLAB_TOKEN ? 'found' : 'NOT found'));
log_message("INFO", "GITLAB_HOST $GITLAB_HOST");

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
sub log_message {
    my ($level, $message) = @_;
    my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime);
    print STDERR "[$timestamp] [$level] $message\n";
    STDERR->flush();
}

# ---------------------------------------------------------------------------
# JSON-RPC helpers
# ---------------------------------------------------------------------------
my $json = JSON->new->allow_nonref;
our $json_pp_encoder = JSON->new->allow_nonref;
our $json_pp_decoder = JSON->new->allow_nonref;

sub respond {
    my ($id, $result) = @_;
    my $response = { jsonrpc => "2.0", id => $id, result => $result };
    print $json->encode($response) . "\n";
    STDOUT->flush();
}

sub respond_error {
    my ($id, $code, $message, $data) = @_;
    my $error = { code => $code, message => $message };
    $error->{data} = $data if defined $data;
    my $response = { jsonrpc => "2.0", id => $id, error => $error };
    print $json->encode($response) . "\n";
    STDOUT->flush();
}

sub send_notification {
    my ($method, $params) = @_;
    my $notification = { jsonrpc => "2.0", method => $method };
    $notification->{params} = $params if defined $params;
    print $json->encode($notification) . "\n";
    STDOUT->flush();
    log_message("INFO", "Notification: $method");
}

# ---------------------------------------------------------------------------
# URL helpers
# ---------------------------------------------------------------------------
sub _uri_escape {
    my ($str) = @_;
    return uri_escape_utf8($str, '^A-Za-z0-9\-\_\.\~');
}

sub _gitlab_project_id {
    my ($project) = @_;
    return '' unless defined $project && length $project;
    # If it looks like a numeric ID, return as-is
    return $project if $project =~ /^\d+$/;
    # Otherwise URL-encode slashes in namespace/project path
    $project =~ s/\//%2F/g;
    return $project;
}

sub _encode_file_path {
    my ($path) = @_;
    $path =~ s/^\///;    # strip leading slash if any
    return _uri_escape($path);
}

# ---------------------------------------------------------------------------
# GitLab REST API helper (via curl)
# ---------------------------------------------------------------------------
sub _gitlab_api {
    my ($method, $path, $body) = @_;
    $method = uc($method // 'GET');
    $path   //= '/';

    my $token = $GITLAB_TOKEN;
    my $url   = "$GITLAB_HOST/api/v4$path";

    log_message("DEBUG", "_gitlab_api: $method $url");

    my $body_arg   = '';
    my $header_arg = '-s';

    if ($token) {
        $header_arg .= " -H 'PRIVATE-TOKEN: $token'";
    }
    $header_arg .= " -H 'User-Agent: gitlab-mcp/1.0'";
    $header_arg .= " -H 'Accept: application/json'";
    $header_arg .= " -H 'Content-Type: application/json'" if defined $body;

    my $tmp_body;
    if (defined $body) {
        $tmp_body = "/tmp/_gitlab_body_$$.json";
        open(my $fh, '>', $tmp_body) or return {
            success => 0,
            status  => 0,
            reason  => "Cannot write temp file: $!",
        };
        print $fh $body;
        close $fh;
        $body_arg = "--data-binary \@'$tmp_body'";
    }

    my $cmd = "curl -s -w '%{http_code}' -X $method $header_arg $body_arg --connect-timeout 10 --max-time 30 '$url' 2>/dev/null";
    log_message("DEBUG", "_gitlab_api: curl cmd generated");

    my $result = `$cmd`;
    unlink $tmp_body if defined $tmp_body && -f $tmp_body;

    my $http_code = '';
    if (length($result) >= 3) {
        $http_code = substr($result, -3, 3);
        $result    = substr($result, 0, -3);
    }
    $http_code =~ s/\s+//g;

    log_message("DEBUG", "_gitlab_api: HTTP $http_code, response_len=" . length($result));

    # Empty body is valid for 204 No Content
    if ($http_code eq '204' || $result eq '') {
        return { success => 1, status => $http_code, data => {} };
    }

    my $data = eval { $json_pp_decoder->decode($result) };
    if ($@) {
        return {
            success => ($http_code =~ /^2/ ? 1 : 0),
            status  => $http_code,
            reason  => "JSON decode error: $@",
        };
    }

    my $success = $http_code =~ /^2/;
    if (!$success && ref $data eq 'HASH') {
        my $reason = $data->{message} // $data->{error} // "HTTP $http_code";
        if ($data->{errors} && ref $data->{errors} eq 'ARRAY') {
            my @msgs = map { ref $_ eq 'HASH' ? ($_->{message} // $_->{code} // '') : $_ } @{$data->{errors}};
            $reason .= ': ' . join('; ', grep { $_ } @msgs) if @msgs;
        }
        return { success => 0, status => $http_code, data => $data, reason => $reason };
    }

    return { success => ($success ? 1 : 0), status => $http_code, data => $data };
}

# ---------------------------------------------------------------------------
# Helper: ensure token is present
# ---------------------------------------------------------------------------
sub _require_token {
    die "GITLAB_TOKEN is not set. Provide via --env gitlab_token=... or GITLAB_TOKEN environment variable."
        unless $GITLAB_TOKEN;
}

# ---------------------------------------------------------------------------
# Tool: gitlab_project_list
# ---------------------------------------------------------------------------
sub tool_gitlab_project_list {
    my ($args) = @_;
    _require_token();

    my $membership = $args->{membership} // 'true';
    my $search     = $args->{search}     // undef;
    my $limit      = $args->{limit}      // 30;
    my $order_by   = $args->{order_by}   // 'last_activity_at';
    my $sort       = $args->{sort}       // 'desc';

    my $path = "/projects?membership=$membership&per_page=$limit&order_by=$order_by&sort=$sort";
    $path .= "&search=" . _uri_escape($search) if $search;

    my $res = _gitlab_api("GET", $path);
    die $res->{reason} unless $res->{success};

    my @projects;
    for my $p (@{$res->{data} // []}) {
        push @projects, {
            id                     => $p->{id},
            name                   => $p->{name}                   // '',
            path_with_namespace    => $p->{path_with_namespace}    // '',
            description            => $p->{description}            // '',
            web_url                => $p->{web_url}                // '',
            default_branch         => $p->{default_branch}         // '',
            visibility             => $p->{visibility}             // '',
            last_activity_at       => $p->{last_activity_at}       // '',
            created_at             => $p->{created_at}             // '',
        };
    }
    return { projects => \@projects, count => scalar @projects };
}

# ---------------------------------------------------------------------------
# Tool: gitlab_project_get
# ---------------------------------------------------------------------------
sub tool_gitlab_project_get {
    my ($args) = @_;
    _require_token();

    my $project = $args->{project} or die "Missing required: project";
    my $pid     = _gitlab_project_id($project);

    my $res = _gitlab_api("GET", "/projects/$pid");
    die $res->{reason} unless $res->{success};

    my $p = $res->{data};
    return {
        id                  => $p->{id},
        name                => $p->{name}                // '',
        path_with_namespace => $p->{path_with_namespace} // '',
        description         => $p->{description}         // '',
        web_url             => $p->{web_url}             // '',
        default_branch      => $p->{default_branch}      // '',
        visibility          => $p->{visibility}          // '',
        created_at          => $p->{created_at}          // '',
        last_activity_at    => $p->{last_activity_at}    // '',
        namespace           => $p->{namespace}           // {},
        owner               => $p->{owner}               // {},
        statistics          => $p->{statistics}          // {},
    };
}

# ---------------------------------------------------------------------------
# Tool: gitlab_issue_list
# ---------------------------------------------------------------------------
sub tool_gitlab_issue_list {
    my ($args) = @_;
    _require_token();

    my $project  = $args->{project}  or die "Missing required: project";
    my $state    = $args->{state}    // 'opened';
    my $labels   = $args->{labels}   // undef;
    my $limit    = $args->{limit}    // 30;
    my $order_by = $args->{order_by} // 'created_at';
    my $sort     = $args->{sort}     // 'desc';

    my $pid = _gitlab_project_id($project);
    my $path = "/projects/$pid/issues?state=$state&per_page=$limit&order_by=$order_by&sort=$sort";
    $path .= "&labels=" . _uri_escape($labels) if $labels;

    my $res = _gitlab_api("GET", $path);
    die $res->{reason} unless $res->{success};

    my @issues;
    for my $issue (@{$res->{data} // []}) {
        push @issues, {
            iid              => $issue->{iid},
            title            => $issue->{title}            // '',
            state            => $issue->{state}            // '',
            web_url          => $issue->{web_url}          // '',
            labels           => $issue->{labels}           // [],
            assignees        => [ map { $_->{username} } @{$issue->{assignees} // []} ],
            created_at       => $issue->{created_at}       // '',
            updated_at       => $issue->{updated_at}       // '',
        };
    }
    return { issues => \@issues, count => scalar @issues };
}

# ---------------------------------------------------------------------------
# Tool: gitlab_issue_get
# ---------------------------------------------------------------------------
sub tool_gitlab_issue_get {
    my ($args) = @_;
    _require_token();

    my $project   = $args->{project}   or die "Missing required: project";
    my $issue_iid = $args->{issue_iid} or die "Missing required: issue_iid";

    my $pid = _gitlab_project_id($project);
    my $res = _gitlab_api("GET", "/projects/$pid/issues/$issue_iid");
    die $res->{reason} unless $res->{success};

    my $issue = $res->{data};
    return {
        iid              => $issue->{iid},
        title            => $issue->{title}            // '',
        description      => $issue->{description}      // '',
        state            => $issue->{state}            // '',
        web_url          => $issue->{web_url}          // '',
        labels           => $issue->{labels}           // [],
        assignees        => [ map { $_->{username} } @{$issue->{assignees} // []} ],
        author           => ($issue->{author} // {})->{username} // '',
        created_at       => $issue->{created_at}       // '',
        updated_at       => $issue->{updated_at}       // '',
        closed_at        => $issue->{closed_at}        // undef,
        due_date         => $issue->{due_date}         // undef,
        user_notes_count => $issue->{user_notes_count} // 0,
    };
}

# ---------------------------------------------------------------------------
# Tool: gitlab_issue_create
# ---------------------------------------------------------------------------
sub tool_gitlab_issue_create {
    my ($args) = @_;
    _require_token();

    my $project     = $args->{project}     or die "Missing required: project";
    my $title       = $args->{title}       or die "Missing required: title";
    my $description = $args->{description} // '';
    my $labels      = $args->{labels}      // undef;
    my $assignee_ids = $args->{assignee_ids} // undef;
    my $due_date    = $args->{due_date}    // undef;

    my %payload = ( title => $title, description => $description );
    $payload{labels}       = $labels       if defined $labels;
    $payload{assignee_ids} = $assignee_ids if defined $assignee_ids;
    $payload{due_date}     = $due_date     if defined $due_date;

    my $body_str = $json_pp_encoder->encode(\%payload);
    my $pid      = _gitlab_project_id($project);
    my $res      = _gitlab_api("POST", "/projects/$pid/issues", $body_str);
    die $res->{reason} unless $res->{success};

    my $issue = $res->{data};
    return {
        issue_iid   => $issue->{iid},
        title       => $issue->{title},
        state       => $issue->{state},
        web_url     => $issue->{web_url},
        created_at  => $issue->{created_at},
    };
}

# ---------------------------------------------------------------------------
# Tool: gitlab_issue_update
# ---------------------------------------------------------------------------
sub tool_gitlab_issue_update {
    my ($args) = @_;
    _require_token();

    my $project   = $args->{project}   or die "Missing required: project";
    my $issue_iid = $args->{issue_iid} or die "Missing required: issue_iid";

    my %payload;
    $payload{title}        = $args->{title}        if defined $args->{title};
    $payload{description}  = $args->{description}  if defined $args->{description};
    $payload{state_event}  = $args->{state_event}  if defined $args->{state_event};
    $payload{labels}       = $args->{labels}       if defined $args->{labels};
    $payload{assignee_ids} = $args->{assignee_ids} if defined $args->{assignee_ids};
    $payload{due_date}     = $args->{due_date}     if defined $args->{due_date};

    die "Nothing to update" unless scalar keys %payload;

    my $body_str = $json_pp_encoder->encode(\%payload);
    my $pid      = _gitlab_project_id($project);
    my $res      = _gitlab_api("PUT", "/projects/$pid/issues/$issue_iid", $body_str);
    die $res->{reason} unless $res->{success};

    my $issue = $res->{data};
    return {
        issue_iid  => $issue->{iid},
        title      => $issue->{title},
        state      => $issue->{state},
        updated_at => $issue->{updated_at},
    };
}

# ---------------------------------------------------------------------------
# Tool: gitlab_issue_add_comment
# ---------------------------------------------------------------------------
sub tool_gitlab_issue_add_comment {
    my ($args) = @_;
    _require_token();

    my $project   = $args->{project}   or die "Missing required: project";
    my $issue_iid = $args->{issue_iid} or die "Missing required: issue_iid";
    my $body      = $args->{body}      or die "Missing required: body";

    my $body_str = $json_pp_encoder->encode({ body => $body });
    my $pid      = _gitlab_project_id($project);
    my $res      = _gitlab_api("POST", "/projects/$pid/issues/$issue_iid/notes", $body_str);
    die $res->{reason} unless $res->{success};

    my $note = $res->{data};
    return {
        note_id    => $note->{id},
        body       => $note->{body}       // '',
        author     => ($note->{author} // {})->{username} // '',
        created_at => $note->{created_at} // '',
    };
}

# ---------------------------------------------------------------------------
# Tool: gitlab_mr_list
# ---------------------------------------------------------------------------
sub tool_gitlab_mr_list {
    my ($args) = @_;
    _require_token();

    my $project  = $args->{project}  or die "Missing required: project";
    my $state    = $args->{state}    // 'opened';
    my $labels   = $args->{labels}   // undef;
    my $limit    = $args->{limit}    // 30;
    my $order_by = $args->{order_by} // 'created_at';
    my $sort     = $args->{sort}     // 'desc';

    my $pid = _gitlab_project_id($project);
    my $path = "/projects/$pid/merge_requests?state=$state&per_page=$limit&order_by=$order_by&sort=$sort";
    $path .= "&labels=" . _uri_escape($labels) if $labels;

    my $res = _gitlab_api("GET", $path);
    die $res->{reason} unless $res->{success};

    my @mrs;
    for my $mr (@{$res->{data} // []}) {
        push @mrs, {
            mr_iid        => $mr->{iid},
            title         => $mr->{title}         // '',
            state         => $mr->{state}         // '',
            source_branch => $mr->{source_branch} // '',
            target_branch => $mr->{target_branch} // '',
            web_url       => $mr->{web_url}       // '',
            author        => ($mr->{author} // {})->{username} // '',
            created_at    => $mr->{created_at}    // '',
            updated_at    => $mr->{updated_at}    // '',
        };
    }
    return { mrs => \@mrs, count => scalar @mrs };
}

# ---------------------------------------------------------------------------
# Tool: gitlab_mr_get
# ---------------------------------------------------------------------------
sub tool_gitlab_mr_get {
    my ($args) = @_;
    _require_token();

    my $project = $args->{project} or die "Missing required: project";
    my $mr_iid  = $args->{mr_iid}  or die "Missing required: mr_iid";

    my $pid = _gitlab_project_id($project);

    # Get MR details
    my $res = _gitlab_api("GET", "/projects/$pid/merge_requests/$mr_iid");
    die $res->{reason} unless $res->{success};

    my $mr = $res->{data};

    # Get diff as separate call
    my $diff_res = _gitlab_api("GET", "/projects/$pid/merge_requests/$mr_iid/diffs");
    my @diffs;
    if ($diff_res->{success}) {
        @diffs = @{$diff_res->{data} // []};
    }

    return {
        mr_iid        => $mr->{iid},
        title         => $mr->{title}         // '',
        description   => $mr->{description}   // '',
        state         => $mr->{state}         // '',
        source_branch => $mr->{source_branch} // '',
        target_branch => $mr->{target_branch} // '',
        merge_status  => $mr->{merge_status} // '',
        draft         => $mr->{draft}         // 0,
        web_url       => $mr->{web_url}       // '',
        author        => ($mr->{author} // {})->{username} // '',
        assignees     => [ map { $_->{username} } @{$mr->{assignees} // []} ],
        created_at    => $mr->{created_at}    // '',
        updated_at    => $mr->{updated_at}    // '',
        diff_count    => scalar @diffs,
        diffs         => \@diffs,
    };
}

# ---------------------------------------------------------------------------
# Tool: gitlab_mr_create
# ---------------------------------------------------------------------------
sub tool_gitlab_mr_create {
    my ($args) = @_;
    _require_token();

    my $project        = $args->{project}        or die "Missing required: project";
    my $title          = $args->{title}          or die "Missing required: title";
    my $source_branch  = $args->{source_branch}  or die "Missing required: source_branch";
    my $target_branch  = $args->{target_branch}  or die "Missing required: target_branch";
    my $description    = $args->{description}    // '';
    my $squash         = $args->{squash}         // undef;
    my $remove_source_branch = $args->{remove_source_branch} // undef;
    my $draft          = $args->{draft}          // undef;

    my %payload = (
        title              => $title,
        source_branch      => $source_branch,
        target_branch      => $target_branch,
        description        => $description,
    );
    $payload{squash}                = $squash                if defined $squash;
    $payload{remove_source_branch}  = $remove_source_branch  if defined $remove_source_branch;
    $payload{draft}                 = $draft                 if defined $draft;

    my $body_str = $json_pp_encoder->encode(\%payload);
    my $pid      = _gitlab_project_id($project);
    my $res      = _gitlab_api("POST", "/projects/$pid/merge_requests", $body_str);
    die $res->{reason} unless $res->{success};

    my $mr = $res->{data};
    return {
        mr_iid        => $mr->{iid},
        title         => $mr->{title},
        state         => $mr->{state},
        source_branch => $mr->{source_branch},
        target_branch => $mr->{target_branch},
        web_url       => $mr->{web_url},
        created_at    => $mr->{created_at},
    };
}

# ---------------------------------------------------------------------------
# Tool: gitlab_mr_merge
# ---------------------------------------------------------------------------
sub tool_gitlab_mr_merge {
    my ($args) = @_;
    _require_token();

    my $project        = $args->{project}        or die "Missing required: project";
    my $mr_iid         = $args->{mr_iid}         or die "Missing required: mr_iid";
    my $squash         = $args->{squash}         // undef;
    my $should_remove_source_branch = $args->{should_remove_source_branch} // undef;
    my $merge_commit_message = $args->{merge_commit_message} // undef;
    my $squash_commit_message = $args->{squash_commit_message} // undef;

    my %payload;
    $payload{squash}                       = $squash                       if defined $squash;
    $payload{should_remove_source_branch}  = $should_remove_source_branch  if defined $should_remove_source_branch;
    $payload{merge_commit_message}         = $merge_commit_message         if defined $merge_commit_message;
    $payload{squash_commit_message}        = $squash_commit_message        if defined $squash_commit_message;

    my $body_str = $json_pp_encoder->encode(\%payload);
    my $pid      = _gitlab_project_id($project);
    my $res      = _gitlab_api("PUT", "/projects/$pid/merge_requests/$mr_iid/merge", $body_str);
    die $res->{reason} unless $res->{success};

    my $mr = $res->{data};
    return {
        mr_iid          => $mr->{iid},
        state           => $mr->{state},
        merged_at       => $mr->{merged_at}       // '',
        merge_commit_sha => $mr->{merge_commit_sha} // '',
    };
}

# ---------------------------------------------------------------------------
# Tool: gitlab_mr_approve
# ---------------------------------------------------------------------------
sub tool_gitlab_mr_approve {
    my ($args) = @_;
    _require_token();

    my $project = $args->{project} or die "Missing required: project";
    my $mr_iid  = $args->{mr_iid}  or die "Missing required: mr_iid";
    my $sha     = $args->{sha}     // undef;

    my %payload;
    $payload{sha} = $sha if defined $sha;

    my $body_str = $json_pp_encoder->encode(\%payload);
    my $pid      = _gitlab_project_id($project);
    my $res      = _gitlab_api("POST", "/projects/$pid/merge_requests/$mr_iid/approve", $body_str);
    die $res->{reason} unless $res->{success};

    my $data = $res->{data};
    return {
        approved       => $data->{approved}       // 0,
        approvals_left => $data->{approvals_left} // 0,
        approved_by    => [ map { $_->{user}{username} // '' } @{$data->{approved_by} // []} ],
    };
}

# ---------------------------------------------------------------------------
# Tool: gitlab_mr_add_comment
# ---------------------------------------------------------------------------
sub tool_gitlab_mr_add_comment {
    my ($args) = @_;
    _require_token();

    my $project = $args->{project} or die "Missing required: project";
    my $mr_iid  = $args->{mr_iid}  or die "Missing required: mr_iid";
    my $body    = $args->{body}    or die "Missing required: body";

    my $body_str = $json_pp_encoder->encode({ body => $body });
    my $pid      = _gitlab_project_id($project);
    my $res      = _gitlab_api("POST", "/projects/$pid/merge_requests/$mr_iid/notes", $body_str);
    die $res->{reason} unless $res->{success};

    my $note = $res->{data};
    return {
        note_id    => $note->{id},
        body       => $note->{body}       // '',
        author     => ($note->{author} // {})->{username} // '',
        created_at => $note->{created_at} // '',
    };
}

# ---------------------------------------------------------------------------
# Tool: gitlab_mr_list_comments
# ---------------------------------------------------------------------------
sub tool_gitlab_mr_list_comments {
    my ($args) = @_;
    _require_token();

    my $project = $args->{project} or die "Missing required: project";
    my $mr_iid  = $args->{mr_iid}  or die "Missing required: mr_iid";
    my $limit   = $args->{limit}   // 30;
    my $sort    = $args->{sort}    // 'desc';

    my $pid = _gitlab_project_id($project);
    my $path = "/projects/$pid/merge_requests/$mr_iid/notes?per_page=$limit&sort=$sort";

    my $res = _gitlab_api("GET", $path);
    die $res->{reason} unless $res->{success};

    my @comments;
    for my $c (@{$res->{data} // []}) {
        push @comments, {
            note_id    => $c->{id},
            body       => $c->{body}       // '',
            author     => ($c->{author} // {})->{username} // '',
            created_at => $c->{created_at} // '',
            updated_at => $c->{updated_at} // '',
        };
    }
    return { comments => \@comments, count => scalar @comments };
}

# ---------------------------------------------------------------------------
# Tool: gitlab_pipeline_list
# ---------------------------------------------------------------------------
sub tool_gitlab_pipeline_list {
    my ($args) = @_;
    _require_token();

    my $project  = $args->{project}  or die "Missing required: project";
    my $status   = $args->{status}   // undef;
    my $ref      = $args->{ref}      // undef;
    my $limit    = $args->{limit}    // 30;
    my $order_by = $args->{order_by} // 'id';
    my $sort     = $args->{sort}     // 'desc';

    my $pid = _gitlab_project_id($project);
    my $path = "/projects/$pid/pipelines?per_page=$limit&order_by=$order_by&sort=$sort";
    $path .= "&status=" . _uri_escape($status) if $status;
    $path .= "&ref="    . _uri_escape($ref)    if $ref;

    my $res = _gitlab_api("GET", $path);
    die $res->{reason} unless $res->{success};

    my @pipelines;
    for my $p (@{$res->{data} // []}) {
        push @pipelines, {
            id         => $p->{id},
            iid        => $p->{iid},
            status     => $p->{status},
            ref        => $p->{ref},
            sha        => $p->{sha},
            web_url    => $p->{web_url},
            created_at => $p->{created_at},
            updated_at => $p->{updated_at},
        };
    }
    return { pipelines => \@pipelines, count => scalar @pipelines };
}

# ---------------------------------------------------------------------------
# Tool: gitlab_pipeline_get
# ---------------------------------------------------------------------------
sub tool_gitlab_pipeline_get {
    my ($args) = @_;
    _require_token();

    my $project     = $args->{project}     or die "Missing required: project";
    my $pipeline_id = $args->{pipeline_id} or die "Missing required: pipeline_id";

    my $pid = _gitlab_project_id($project);
    my $res = _gitlab_api("GET", "/projects/$pid/pipelines/$pipeline_id");
    die $res->{reason} unless $res->{success};

    my $p = $res->{data};
    return {
        id              => $p->{id},
        iid             => $p->{iid},
        status          => $p->{status},
        ref             => $p->{ref},
        sha             => $p->{sha},
        web_url         => $p->{web_url},
        duration        => $p->{duration}        // undef,
        created_at      => $p->{created_at}      // '',
        updated_at      => $p->{updated_at}      // '',
        started_at      => $p->{started_at}      // undef,
        finished_at     => $p->{finished_at}     // undef,
        user            => $p->{user}            // {},
        detailed_status => $p->{detailed_status} // {},
    };
}

# ---------------------------------------------------------------------------
# Tool: gitlab_pipeline_retry
# ---------------------------------------------------------------------------
sub tool_gitlab_pipeline_retry {
    my ($args) = @_;
    _require_token();

    my $project     = $args->{project}     or die "Missing required: project";
    my $pipeline_id = $args->{pipeline_id} or die "Missing required: pipeline_id";

    my $pid = _gitlab_project_id($project);
    my $res = _gitlab_api("POST", "/projects/$pid/pipelines/$pipeline_id/retry");
    die $res->{reason} unless $res->{success};

    my $p = $res->{data};
    return {
        pipeline_id => $p->{id},
        iid         => $p->{iid},
        status      => $p->{status},
        web_url     => $p->{web_url},
    };
}

# ---------------------------------------------------------------------------
# Tool: gitlab_pipeline_cancel
# ---------------------------------------------------------------------------
sub tool_gitlab_pipeline_cancel {
    my ($args) = @_;
    _require_token();

    my $project     = $args->{project}     or die "Missing required: project";
    my $pipeline_id = $args->{pipeline_id} or die "Missing required: pipeline_id";

    my $pid = _gitlab_project_id($project);
    my $res = _gitlab_api("POST", "/projects/$pid/pipelines/$pipeline_id/cancel");
    die $res->{reason} unless $res->{success};

    my $p = $res->{data};
    return {
        pipeline_id => $p->{id},
        iid         => $p->{iid},
        status      => $p->{status},
        web_url     => $p->{web_url},
    };
}

# ---------------------------------------------------------------------------
# Tool: gitlab_file_get
# ---------------------------------------------------------------------------
sub tool_gitlab_file_get {
    my ($args) = @_;
    _require_token();

    my $project   = $args->{project}   or die "Missing required: project";
    my $file_path = $args->{file_path} or die "Missing required: file_path";
    my $ref       = $args->{ref}       // undef;

    my $pid  = _gitlab_project_id($project);
    my $path = "/projects/$pid/repository/files/" . _encode_file_path($file_path);
    $path .= "?ref=" . _uri_escape($ref) if $ref;

    my $res = _gitlab_api("GET", $path);
    die $res->{reason} unless $res->{success};

    my $data = $res->{data};
    my $content = '';
    my $size = 0;
    if ($data->{content}) {
        my $decoded = decode_base64($data->{content});
        utf8::decode($decoded) unless utf8::is_utf8($decoded);
        $content = $decoded;
        $size = length($content);
    }

    return {
        file_name     => $data->{file_name}     // '',
        file_path     => $data->{file_path}     // $file_path,
        size          => $size,
        encoding      => $data->{encoding}      // 'base64',
        content       => $content,
        blob_id       => $data->{blob_id}       // '',
        commit_id     => $data->{commit_id}     // '',
        last_commit_id => $data->{last_commit_id} // '',
        ref           => $data->{ref}           // ($ref // ''),
    };
}

# ---------------------------------------------------------------------------
# Tool: gitlab_file_create_or_update
# ---------------------------------------------------------------------------
sub tool_gitlab_file_create_or_update {
    my ($args) = @_;
    _require_token();

    my $project        = $args->{project}        or die "Missing required: project";
    my $file_path      = $args->{file_path}      or die "Missing required: file_path";
    my $content        = $args->{content}        // '';
    my $commit_message = $args->{commit_message} or die "Missing required: commit_message";
    my $branch         = $args->{branch}         or die "Missing required: branch";
    my $start_branch   = $args->{start_branch}   // undef;
    my $author_email   = $args->{author_email}   // undef;
    my $author_name    = $args->{author_name}    // undef;
    my $last_commit_id = $args->{last_commit_id} // undef;

    my $encoded = encode_base64($content, '');
    my %payload = (
        branch         => $branch,
        content        => $encoded,
        commit_message => $commit_message,
    );
    $payload{start_branch}   = $start_branch   if defined $start_branch;
    $payload{author_email}   = $author_email   if defined $author_email;
    $payload{author_name}    = $author_name    if defined $author_name;
    $payload{last_commit_id} = $last_commit_id if defined $last_commit_id;

    my $body_str = $json_pp_encoder->encode(\%payload);
    my $pid      = _gitlab_project_id($project);
    my $api_path = "/projects/$pid/repository/files/" . _encode_file_path($file_path);

    # Try create first (POST)
    my $res = _gitlab_api("POST", $api_path, $body_str);

    # If file exists (typically 400), try update (PUT)
    if (!$res->{success} && $res->{status} =~ /^4/) {
        log_message("INFO", "File may exist, retrying with PUT for update");
        $res = _gitlab_api("PUT", $api_path, $body_str);
    }

    die $res->{reason} unless $res->{success};

    my $data = $res->{data};
    return {
        file_path  => $data->{file_path}  // $file_path,
        branch     => $data->{branch}     // $branch,
        commit_id  => $data->{commit_id} // ($data->{commit} // {})->{id} // '',
    };
}

# ---------------------------------------------------------------------------
# Tool registry
# ---------------------------------------------------------------------------
my %tool_handlers = (
    gitlab_project_list => {
        description => "List accessible GitLab projects",
        inputSchema => {
            type => "object",
            required => [],
            properties => {
                membership => { type => "string", description => "Only projects user is member of: true or false (default: true)" },
                search     => { type => "string", description => "Search projects by name (optional)" },
                limit      => { type => "number", description => "Max results (default: 30)" },
                order_by   => { type => "string", description => "Field to order by: id, name, path, created_at, updated_at, last_activity_at (default: last_activity_at)" },
                sort       => { type => "string", description => "Sort order: asc or desc (default: desc)" },
            },
        },
        handler => \&tool_gitlab_project_list,
    },
    gitlab_project_get => {
        description => "Get details of a GitLab project",
        inputSchema => {
            type => "object",
            required => ["project"],
            properties => {
                project => { type => "string", description => "Project ID (numeric) or URL-encoded path (namespace/project)" },
            },
        },
        handler => \&tool_gitlab_project_get,
    },
    gitlab_issue_list => {
        description => "List issues in a GitLab project with filters",
        inputSchema => {
            type => "object",
            required => ["project"],
            properties => {
                project  => { type => "string", description => "Project ID (numeric) or URL-encoded path" },
                state    => { type => "string", description => "opened, closed, or all (default: opened)" },
                labels   => { type => "string", description => "Comma-separated label names (optional)" },
                limit    => { type => "number", description => "Max results (default: 30)" },
                order_by => { type => "string", description => "created_at or updated_at (default: created_at)" },
                sort     => { type => "string", description => "asc or desc (default: desc)" },
            },
        },
        handler => \&tool_gitlab_issue_list,
    },
    gitlab_issue_get => {
        description => "Get details of a specific GitLab issue",
        inputSchema => {
            type => "object",
            required => ["project", "issue_iid"],
            properties => {
                project   => { type => "string", description => "Project ID (numeric) or URL-encoded path" },
                issue_iid => { type => "number", description => "Issue IID (project-scoped)" },
            },
        },
        handler => \&tool_gitlab_issue_get,
    },
    gitlab_issue_create => {
        description => "Create a new issue in a GitLab project",
        inputSchema => {
            type => "object",
            required => ["project", "title"],
            properties => {
                project      => { type => "string", description => "Project ID (numeric) or URL-encoded path" },
                title        => { type => "string", description => "Issue title" },
                description  => { type => "string", description => "Issue body (optional)" },
                labels       => { type => "string", description => "Comma-separated label names (optional)" },
                assignee_ids => { type => "array", items => { type => "number" }, description => "Array of user IDs to assign (optional)" },
                due_date     => { type => "string", description => "Due date in YYYY-MM-DD format (optional)" },
            },
        },
        handler => \&tool_gitlab_issue_create,
    },
    gitlab_issue_update => {
        description => "Update a GitLab issue (title, body, state, labels, assignees)",
        inputSchema => {
            type => "object",
            required => ["project", "issue_iid"],
            properties => {
                project      => { type => "string", description => "Project ID (numeric) or URL-encoded path" },
                issue_iid    => { type => "number", description => "Issue IID (project-scoped)" },
                title        => { type => "string", description => "New title (optional)" },
                description  => { type => "string", description => "New body (optional)" },
                state_event  => { type => "string", description => "close or reopen (optional)" },
                labels       => { type => "string", description => "Comma-separated label names (optional)" },
                assignee_ids => { type => "array", items => { type => "number" }, description => "Array of user IDs (optional)" },
                due_date     => { type => "string", description => "Due date in YYYY-MM-DD format (optional)" },
            },
        },
        handler => \&tool_gitlab_issue_update,
    },
    gitlab_issue_add_comment => {
        description => "Add a comment to a GitLab issue",
        inputSchema => {
            type => "object",
            required => ["project", "issue_iid", "body"],
            properties => {
                project   => { type => "string", description => "Project ID (numeric) or URL-encoded path" },
                issue_iid => { type => "number", description => "Issue IID (project-scoped)" },
                body      => { type => "string", description => "Comment body text" },
            },
        },
        handler => \&tool_gitlab_issue_add_comment,
    },
    gitlab_mr_list => {
        description => "List merge requests in a GitLab project with filters",
        inputSchema => {
            type => "object",
            required => ["project"],
            properties => {
                project  => { type => "string", description => "Project ID (numeric) or URL-encoded path" },
                state    => { type => "string", description => "opened, closed, merged, or all (default: opened)" },
                labels   => { type => "string", description => "Comma-separated label names (optional)" },
                limit    => { type => "number", description => "Max results (default: 30)" },
                order_by => { type => "string", description => "created_at or updated_at (default: created_at)" },
                sort     => { type => "string", description => "asc or desc (default: desc)" },
            },
        },
        handler => \&tool_gitlab_mr_list,
    },
    gitlab_mr_get => {
        description => "Get merge request details and diff",
        inputSchema => {
            type => "object",
            required => ["project", "mr_iid"],
            properties => {
                project => { type => "string", description => "Project ID (numeric) or URL-encoded path" },
                mr_iid  => { type => "number", description => "Merge request IID (project-scoped)" },
            },
        },
        handler => \&tool_gitlab_mr_get,
    },
    gitlab_mr_create => {
        description => "Create a merge request in a GitLab project",
        inputSchema => {
            type => "object",
            required => ["project", "title", "source_branch", "target_branch"],
            properties => {
                project               => { type => "string", description => "Project ID (numeric) or URL-encoded path" },
                title                 => { type => "string", description => "MR title" },
                source_branch         => { type => "string", description => "Source branch" },
                target_branch         => { type => "string", description => "Target branch" },
                description           => { type => "string", description => "MR description (optional)" },
                squash                => { type => "boolean", description => "Squash commits on merge (optional)" },
                remove_source_branch  => { type => "boolean", description => "Remove source branch after merge (optional)" },
                draft                 => { type => "boolean", description => "Create as draft (optional)" },
            },
        },
        handler => \&tool_gitlab_mr_create,
    },
    gitlab_mr_merge => {
        description => "Merge a merge request (with squash option)",
        inputSchema => {
            type => "object",
            required => ["project", "mr_iid"],
            properties => {
                project                     => { type => "string", description => "Project ID (numeric) or URL-encoded path" },
                mr_iid                      => { type => "number", description => "Merge request IID" },
                squash                      => { type => "boolean", description => "Squash commits on merge (optional)" },
                should_remove_source_branch => { type => "boolean", description => "Remove source branch after merge (optional)" },
                merge_commit_message        => { type => "string", description => "Merge commit message (optional)" },
                squash_commit_message       => { type => "string", description => "Squash commit message (optional)" },
            },
        },
        handler => \&tool_gitlab_mr_merge,
    },
    gitlab_mr_approve => {
        description => "Approve a merge request",
        inputSchema => {
            type => "object",
            required => ["project", "mr_iid"],
            properties => {
                project => { type => "string", description => "Project ID (numeric) or URL-encoded path" },
                mr_iid  => { type => "number", description => "Merge request IID" },
                sha     => { type => "string", description => "HEAD SHA to approve (optional)" },
            },
        },
        handler => \&tool_gitlab_mr_approve,
    },
    gitlab_mr_add_comment => {
        description => "Add a comment to a merge request",
        inputSchema => {
            type => "object",
            required => ["project", "mr_iid", "body"],
            properties => {
                project => { type => "string", description => "Project ID (numeric) or URL-encoded path" },
                mr_iid  => { type => "number", description => "Merge request IID" },
                body    => { type => "string", description => "Comment body text" },
            },
        },
        handler => \&tool_gitlab_mr_add_comment,
    },
    gitlab_mr_list_comments => {
        description => "List comments on a merge request",
        inputSchema => {
            type => "object",
            required => ["project", "mr_iid"],
            properties => {
                project => { type => "string", description => "Project ID (numeric) or URL-encoded path" },
                mr_iid  => { type => "number", description => "Merge request IID" },
                limit   => { type => "number", description => "Max results (default: 30)" },
                sort    => { type => "string", description => "asc or desc (default: desc)" },
            },
        },
        handler => \&tool_gitlab_mr_list_comments,
    },
    gitlab_pipeline_list => {
        description => "List CI/CD pipelines for a project",
        inputSchema => {
            type => "object",
            required => ["project"],
            properties => {
                project  => { type => "string", description => "Project ID (numeric) or URL-encoded path" },
                status   => { type => "string", description => "running, pending, success, failed, canceled, skipped (optional)" },
                ref      => { type => "string", description => "Branch or tag name (optional)" },
                limit    => { type => "number", description => "Max results (default: 30)" },
                order_by => { type => "string", description => "id, status, ref, updated_at, or user_id (default: id)" },
                sort     => { type => "string", description => "asc or desc (default: desc)" },
            },
        },
        handler => \&tool_gitlab_pipeline_list,
    },
    gitlab_pipeline_get => {
        description => "Get details of a CI/CD pipeline",
        inputSchema => {
            type => "object",
            required => ["project", "pipeline_id"],
            properties => {
                project     => { type => "string", description => "Project ID (numeric) or URL-encoded path" },
                pipeline_id => { type => "number", description => "Pipeline ID (global)" },
            },
        },
        handler => \&tool_gitlab_pipeline_get,
    },
    gitlab_pipeline_retry => {
        description => "Retry failed or canceled jobs in a pipeline",
        inputSchema => {
            type => "object",
            required => ["project", "pipeline_id"],
            properties => {
                project     => { type => "string", description => "Project ID (numeric) or URL-encoded path" },
                pipeline_id => { type => "number", description => "Pipeline ID (global)" },
            },
        },
        handler => \&tool_gitlab_pipeline_retry,
    },
    gitlab_pipeline_cancel => {
        description => "Cancel a running pipeline",
        inputSchema => {
            type => "object",
            required => ["project", "pipeline_id"],
            properties => {
                project     => { type => "string", description => "Project ID (numeric) or URL-encoded path" },
                pipeline_id => { type => "number", description => "Pipeline ID (global)" },
            },
        },
        handler => \&tool_gitlab_pipeline_cancel,
    },
    gitlab_file_get => {
        description => "Get file contents from a GitLab repository",
        inputSchema => {
            type => "object",
            required => ["project", "file_path"],
            properties => {
                project   => { type => "string", description => "Project ID (numeric) or URL-encoded path" },
                file_path => { type => "string", description => "File path in repository" },
                ref       => { type => "string", description => "Branch, tag, or commit SHA (optional, defaults to default branch)" },
            },
        },
        handler => \&tool_gitlab_file_get,
    },
    gitlab_file_create_or_update => {
        description => "Create or update a file in a GitLab repository",
        inputSchema => {
            type => "object",
            required => ["project", "file_path", "content", "commit_message", "branch"],
            properties => {
                project        => { type => "string", description => "Project ID (numeric) or URL-encoded path" },
                file_path      => { type => "string", description => "File path to create/update" },
                content        => { type => "string", description => "File content (text)" },
                commit_message => { type => "string", description => "Commit message" },
                branch         => { type => "string", description => "Target branch" },
                start_branch   => { type => "string", description => "New branch to create, diverging from branch (optional)" },
                author_email   => { type => "string", description => "Author email (optional)" },
                author_name    => { type => "string", description => "Author name (optional)" },
                last_commit_id => { type => "string", description => "Last commit ID for optimistic locking (optional)" },
            },
        },
        handler => \&tool_gitlab_file_create_or_update,
    },
);

# ---------------------------------------------------------------------------
# MCP main loop
# ---------------------------------------------------------------------------
log_message("INFO", "gitlab-mcp server started");

LINE: while (my $line = <STDIN>) {
    chomp $line;
    next LINE unless $line && $line =~ /\S/;

    log_message("DEBUG", "Received: $line");

    my $msg = eval { $json->decode($line) };
    if ($@ || !$msg) {
        log_message("ERROR", "Invalid JSON-RPC message: $@");
        next LINE;
    }

    my $id     = $msg->{id};
    my $method = $msg->{method} // '';
    my $params = $msg->{params} // {};

    # Notifications (no id) - just log
    if (!defined $id) {
        log_message("INFO", "Received notification: $method");
        next LINE;
    }

    if ($method eq 'initialize') {
        respond($id, {
            protocolVersion => '2024-11-05',
            capabilities    => { tools => {} },
            serverInfo      => {
                name    => 'gitlab-mcp',
                version => '1.0.0',
            },
        });
        log_message("INFO", "Initialized");
    }
    elsif ($method eq 'ping') {
        respond($id, {});
        log_message("INFO", "Ping");
    }
    elsif ($method eq 'tools/list') {
        my @tool_defs;
        for my $name (sort keys %tool_handlers) {
            push @tool_defs, {
                name        => $name,
                description => $tool_handlers{$name}{description},
                inputSchema => $tool_handlers{$name}{inputSchema},
            };
        }
        respond($id, { tools => \@tool_defs });
        log_message("INFO", "Sent tool list (" . scalar(@tool_defs) . " tools)");
    }
    elsif ($method eq 'tools/call') {
        my $tool_name = $params->{name} // '';
        my $tool_args = $params->{arguments} // {};

        unless (exists $tool_handlers{$tool_name}) {
            respond_error($id, -32601, "Method not found: tool '$tool_name' not found");
            next LINE;
        }

        log_message("INFO", "Executing tool: $tool_name");

        eval {
            my $result = $tool_handlers{$tool_name}{handler}->($tool_args);
            log_message("INFO", "Tool '$tool_name' execution successful");
            respond($id, {
                content => [
                    {
                        type => "text",
                        text => $json->encode($result),
                    },
                ],
            });
        };
        if ($@) {
            my $error_msg = $@;
            chomp $error_msg;
            log_message("ERROR", "Tool '$tool_name' execution error: $error_msg");
            respond_error($id, -32603, "Internal error: $error_msg");
        }
    }
    elsif ($method eq 'resources/list') {
        respond($id, { resources => [] });
        log_message("INFO", "Sent empty resource list");
    }
    elsif ($method eq 'prompts/list') {
        respond($id, { prompts => [] });
        log_message("INFO", "Sent empty prompt list");
    }
    else {
        log_message("WARN", "Unknown method: $method");
        respond_error($id, -32601, "Method not found: $method");
    }
}

log_message("INFO", "gitlab-mcp server stopped");
