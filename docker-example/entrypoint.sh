#!/usr/bin/env bash
set -e

if [[ -d "${HOME}" && ! -O "${HOME}" ]]; then
  # Migrate volumes previously created for the root user.
  sudo chown -R "$(id -u):$(id -g)" "${HOME}" 2>/dev/null || true
fi

if [[ -f "${HOME}/.bashrc" && "${1##*/}" != "bash" ]]; then
  # Load the interactive shell environment before resolving commands from PATH.
  exec bash --noprofile --rcfile "${HOME}/.bashrc" -ic 'exec "$@"' entrypoint "$@"
fi

exec "$@"
