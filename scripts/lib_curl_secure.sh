#!/usr/bin/env bash
# Encore Radio - shared helper for making a curl request that carries a
# secret (a bearer token, a client secret via Basic auth, a license key)
# without that secret ever appearing in the process's own argv - which
# `ps` shows, in full, to every local user and process on the box, not
# just root. -u/-d/-H on the command line all land in argv; curl's own
# -K/--config file does not.
#
# Verified empirically (not just read off the curl manpage) that curl's
# config-file quoting round-trips a value containing both a literal `"`
# and a literal `\` correctly when backslash is escaped first and the
# quote second - confirmed byte-for-byte via a local test server before
# this was used anywhere real.

# Escapes a value for safe embedding inside a double-quoted curl -K
# config string. Backslash first - escaping it after the quote would
# double-escape the quote's own leading backslash.
#
# Also strips \r/\n - not escapes, strips. Confirmed empirically (not
# just suspected) that curl's config-file parser splits on a literal
# newline BEFORE it ever looks at quoting: a value containing one
# truncates at that point and whatever follows becomes a brand new
# config directive, quote or no quote. Reported finding: a license key
# of "abc<newline>output /some/path<newline>#" made curl write the
# server's response to that path - verified with a local test server
# (the POST body curl actually sent was cut off exactly at the
# newline). save.php is the primary fix (strips \r/\n from every field
# that lands here before it ever reaches this function) - this is the
# backstop for any value that reaches here anyway, including values
# this codebase doesn't fully control itself (an OAuth token/response
# field, for instance).
er_curl_cfg_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\r'/}"
    s="${s//$'\n'/}"
    printf '%s' "$s"
}

# er_curl_secure <cfg_lines> <curl_args...>
#
# cfg_lines: one or more curl config-file directives (e.g. `header = "..."`,
# `data = "..."`, `user = "..."`), newline-separated, already escaped via
# er_curl_cfg_escape wherever a secret or arbitrary value is embedded.
# Everything else about the request (URL, method, -s/-m/-o/-w/etc, none of
# which are secret) is passed as ordinary curl_args, same as any other
# curl call in this codebase.
#
# Written to a mktemp'd 0600 file rather than piped via -K - (stdin) -
# this plugin runs some of these as root, and a few call sites already
# use mktemp for response files specifically to avoid a predictable /tmp
# path being pre-planted as a symlink by another local user; match that
# here for the config file too.
er_curl_secure() {
    local cfg_body="$1"; shift
    local cfg_file
    cfg_file="$(mktemp /tmp/er_curlcfg.XXXXXX)" || return 1
    chmod 600 "$cfg_file"
    printf '%s\n' "$cfg_body" > "$cfg_file"
    # --max-time here is a fallback ceiling, not the real timeout - every
    # call site already passes its own -m via curl_args below, and curl
    # takes the LAST occurrence of a repeated flag (confirmed empirically:
    # `-m 20 -m 3` against a slow endpoint aborted at ~3s, not 20s), so a
    # caller's own tighter value always wins. This exists so the actual
    # timeout is visible as a plain, static flag on this line rather than
    # only ever arriving via the dynamically-built curl_args a static
    # scanner can't resolve - and so nothing here can hang indefinitely
    # even if some future caller forgets to pass its own.
    curl -K "$cfg_file" --max-time 20 "$@"
    local rc=$?
    rm -f "$cfg_file"
    return $rc
}
