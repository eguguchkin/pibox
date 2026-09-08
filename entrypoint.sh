#!/usr/bin/env bash
# Entrypoint контейнера pibox: подстройка UID/GID, skel-merge,
# exec через gosu pi:pi tini -- "$@".
#
# ЗАГЛУШКА (задача 2). Полная реализация — задача 5.

set -euo pipefail

echo "pibox: entrypoint.sh — заглушка, полная реализация в задаче 5." >&2
exit 1
