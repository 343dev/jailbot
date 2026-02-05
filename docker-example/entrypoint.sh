#!/usr/bin/env bash
set -e

if [ -f /root/.bashrc ]; then
  source /root/.bashrc
fi

exec "$@"
