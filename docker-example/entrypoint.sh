#!/usr/bin/env bash
set -e

if [[ -d "${HOME}" && ! -O "${HOME}" ]]; then
  # Migrate volumes previously created for the root user.
  sudo chown -R "$(id -u):$(id -g)" "${HOME}" 2>/dev/null || true
fi

if [[ -f "${HOME}/.bashrc" ]]; then
  # shellcheck source=/dev/null
  source "${HOME}/.bashrc"
fi

exec "$@"
