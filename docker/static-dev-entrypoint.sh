#!/usr/bin/env bash
# Entrypoint for the Stage B interactive dev image (docker/static-dev.Dockerfile).
#
# Resolves the host user's uid/gid (from HOST_UID/HOST_GID or by stat-ing the
# bind-mounted /work), materialises a matching user inside the container,
# grants it NOPASSWD sudo (needed for perf/bpftrace/strace under SYS_PTRACE),
# registers serena as Claude Code's MCP server, then drops privileges via
# su-exec and execs the requested command.
#
# Mirrors docker/eco-dev-entrypoint.sh; differences are intentional:
#   - no background serena daemon (claude spawns it per session)
#   - no env re-exports (Dockerfile ENV is canonical)
set -euo pipefail

DEFAULT_USER="dev"
DEFAULT_UID=1000
DEFAULT_GID=1000

# 1) Decide the target UID/GID
uid="${HOST_UID:-}"
gid="${HOST_GID:-}"

if [[ -z "${uid}" || -z "${gid}" ]]; then
  if [[ -d "/work" ]]; then
    uid="$(stat -c '%u' /work || echo ${DEFAULT_UID})"
    gid="$(stat -c '%g' /work || echo ${DEFAULT_GID})"
  else
    uid="${DEFAULT_UID}"
    gid="${DEFAULT_GID}"
  fi
fi

# 2) Ensure group exists (shadow's groupadd; falls back to a synthetic name if
# DEFAULT_USER is already taken at a different gid).
if ! getent group "${gid}" >/dev/null 2>&1; then
  groupadd -g "${gid}" "${DEFAULT_USER}" 2>/dev/null || \
  groupadd -g "${gid}" "grp${gid}"
fi
group_name="$(getent group "${gid}" | cut -d: -f1)"

# 3) Ensure user exists
if ! getent passwd "${uid}" >/dev/null 2>&1; then
  useradd -m -u "${uid}" -g "${group_name}" -s /bin/bash "${DEFAULT_USER}" 2>/dev/null || \
  useradd -m -u "${uid}" -g "${gid}" -s /bin/bash "user${uid}"
fi
user_name="$(getent passwd "${uid}" | cut -d: -f1)"
home_dir="$(getent passwd "${uid}" | cut -d: -f6)"

# 4) Grant NOPASSWD sudo. Justified by the workflow: perf, bpftrace and strace
# all need root (or SYS_PTRACE) for the Stage B debug story.
echo "${user_name} ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/${user_name}"
chmod 440 "/etc/sudoers.d/${user_name}"

# 5) Ensure writable HOME and /work
mkdir -p "${home_dir}" /work
chown -R "${uid}:${gid}" "${home_dir}" /work || true

export HOME="${home_dir}"

# 6) Best-effort serena MCP registration (claude spawns it on demand per
# session — no background daemon needed).
if command -v claude >/dev/null 2>&1 && command -v uvx >/dev/null 2>&1; then
  if ! su-exec "${uid}:${gid}" claude mcp get serena >/dev/null 2>&1; then
    su-exec "${uid}:${gid}" claude mcp add serena -- \
      uvx --from git+https://github.com/oraios/serena \
      serena start-mcp-server --context claude-code --project /work \
      >/dev/null 2>&1 || true
  fi
fi

# 7) Default command
if [[ $# -eq 0 ]]; then
  set -- bash
fi

# 8) Drop privileges
exec su-exec "${uid}:${gid}" "$@"
