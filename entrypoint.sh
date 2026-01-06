#!/usr/bin/env bash
set -euo pipefail

# Defaults
DEFAULT_USER="dev"
DEFAULT_UID=1000
DEFAULT_GID=1000

# 1) Decide the target UID/GID
uid="${HOST_UID:-}"
gid="${HOST_GID:-}"

if [[ -z "${uid}" || -z "${gid}" ]]; then
  if [[ -d "/work" ]]; then
    # Owner of the bind-mounted /work directory (Linux-only stat flags)
    uid="$(stat -c '%u' /work || echo ${DEFAULT_UID})"
    gid="$(stat -c '%g' /work || echo ${DEFAULT_GID})"
  else
    uid="${DEFAULT_UID}"
    gid="${DEFAULT_GID}"
  fi
fi

# 2) Ensure group exists
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

# 4) Ensure writable HOME and /work
mkdir -p "${home_dir}" /work
chown -R "${uid}:${gid}" "${home_dir}" /work || true

# 5) Helpful env defaults
export HOME="${home_dir}"
export CMAKE_PREFIX_PATH="/opt/llvm-mlir:${CMAKE_PREFIX_PATH:-}"
export LD_LIBRARY_PATH="/opt/llvm-mlir/lib:${LD_LIBRARY_PATH:-}"
export PATH="/opt/llvm-mlir/bin:${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
export CC="${CC:-clang}"
export CXX="${CXX:-clang++}"
export PATH=$HOME/.local/bin:$PATH

# 6) Configure serena as MCP server for claude (if not already configured)
claude_settings="${home_dir}/.claude/settings.json"
if [[ ! -f "${claude_settings}" ]] || ! grep -q '"serena"' "${claude_settings}" 2>/dev/null; then
  gosu "${uid}:${gid}" claude mcp add serena -- uvx --from git+https://github.com/oraios/serena serena start-mcp-server --context claude-code --project /work 2>/dev/null || true
fi

# 7) Start serena MCP server in the background
gosu "${uid}:${gid}" bash -c 'nohup uvx --from git+https://github.com/oraios/serena serena start-mcp-server --context claude-code --project /work > /tmp/serena.log 2>&1 &'

# 8) Default command
if [[ $# -eq 0 ]]; then
  set -- bash
fi

# 9) Drop privileges to the detected user
exec gosu "${uid}:${gid}" "$@"
