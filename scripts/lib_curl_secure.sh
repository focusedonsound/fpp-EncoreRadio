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
er_curl_cfg_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
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
    curl -K "$cfg_file" "$@"
    local rc=$?
    rm -f "$cfg_file"
    return $rc
}
