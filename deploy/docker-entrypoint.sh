#!/bin/sh
# Translates container-shaped configuration into fastly-mcp's CLI flags.
#
# Two upstream details make a wrapper worthwhile:
#   - --http-allow-host is the only HTTP flag with no environment fallback,
#     and every request arriving through a proxy or load balancer carries the
#     public hostname in Host. Without it the server answers 421.
#   - Cloud Run (and Knative generally) injects PORT; the server reads
#     FASTLY_MCP_HTTP_PORT.
set -eu

# The container always binds 0.0.0.0, and the server refuses a non-loopback
# bind without a token. Say so plainly rather than letting the startup error
# scroll past in a platform log.
if [ -z "${FASTLY_MCP_HTTP_AUTH_TOKEN:-}" ]; then
  echo "fastly-mcp: FASTLY_MCP_HTTP_AUTH_TOKEN is required (this container binds 0.0.0.0)." >&2
  exit 2
fi

# An explicit FASTLY_MCP_HTTP_PORT wins over the platform's PORT.
port="${FASTLY_MCP_HTTP_PORT:-${PORT:-8231}}"

# Flags are prepended so anything passed to the container still wins:
# node's parseArgs takes the last occurrence of a string option.
if [ -n "${MCP_ALLOWED_HOSTS:-}" ]; then
  IFS=,
  for host in ${MCP_ALLOWED_HOSTS}; do
    host="$(printf '%s' "$host" | tr -d '[:space:]')"
    [ -n "$host" ] || continue
    set -- --http-allow-host "$host" "$@"
  done
  unset IFS
fi

set -- --transport http --http-host 0.0.0.0 --http-port "$port" "$@"

exec fastly-mcp "$@"
