#!/bin/bash
set -euo pipefail

if [[ $# -gt 0 ]]; then
  echo ":: INFO: ignoring CLI targets; markdown tarball output is the only supported mode"
fi

exec /scripts/build-markdown.sh \
  --zephyr-root /docs/zephyrproject/zephyr \
  --output-dir /output \
  --archive-name "${MARKDOWN_TARBALL_NAME:-markdown.tar.gz}"
