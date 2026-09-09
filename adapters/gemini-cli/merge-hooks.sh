#!/bin/bash
# Render an idempotent JSON-with-comments upgrade; preserve the original file.
set -eu
exec python3 "$(dirname "$0")/merge-hooks.py" "$@"
