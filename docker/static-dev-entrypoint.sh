#!/bin/bash
# Entrypoint for the Stage B interactive dev image (docker/static-dev.Dockerfile).
# Runs as the `dev` user. Registers serena as Claude Code's MCP server so a
# Claude Code session launched inside the container is codebase-aware, then
# execs the requested command (default: an interactive bash shell).
set -uo pipefail

# Best-effort serena MCP registration (claude spawns it on demand per session).
if command -v claude >/dev/null 2>&1 && command -v uvx >/dev/null 2>&1; then
  if ! claude mcp get serena >/dev/null 2>&1; then
    claude mcp add serena -- \
      uvx --from git+https://github.com/oraios/serena \
      serena start-mcp-server --context claude-code --project /work \
      >/dev/null 2>&1 || true
  fi
fi

if [ "$#" -eq 0 ]; then
  set -- bash
fi
exec "$@"
