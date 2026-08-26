#!/bin/bash
# Install the Zephyr SDK a given Zephyr tree asks for.
#
# The per-board supported-hardware tables in the docs are derived from each
# board's devicetree, which the build harvests by configuring every board with
# twister. That needs target toolchains; without them twister fails in
# verify-toolchain.cmake and the tables come out empty.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: install-zephyr-sdk.sh --zephyr-root PATH [--install-dir PATH]

Options:
  --zephyr-root PATH   Zephyr tree whose SDK_VERSION decides the version.
  --install-dir PATH   Where to unpack the SDK. Defaults to /opt.
  -h, --help           Show this help text.

Prints the resolved SDK directory on stdout.
USAGE
}

ZEPHYR_ROOT=""
INSTALL_DIR="/opt"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --zephyr-root) ZEPHYR_ROOT="$2"; shift 2 ;;
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "${ZEPHYR_ROOT}" ]]; then
  usage >&2
  exit 1
fi

if [[ ! -f "${ZEPHYR_ROOT}/SDK_VERSION" ]]; then
  echo "No SDK_VERSION in ${ZEPHYR_ROOT}" >&2
  exit 1
fi

# Never pin: each Zephyr tag states the version it needs, and that has ranged
# from 0.16.5 to 1.0.1 across the tags this repository builds.
SDK_VERSION="$(tr -d '[:space:]' < "${ZEPHYR_ROOT}/SDK_VERSION")"
if [[ -z "${SDK_VERSION}" ]]; then
  echo "SDK_VERSION in ${ZEPHYR_ROOT} is empty" >&2
  exit 1
fi

# A directory alone is not enough: the _minimal bundle unpacks to a valid
# looking SDK containing no toolchains at all. SDK 0.16/0.17 keep toolchains at
# the top level; 1.0 moved them under gnu/.
sdk_has_toolchains() {
  [[ -n "$1" && -d "$1" ]] || return 1
  compgen -G "$1/*-zephyr-*" > /dev/null || compgen -G "$1/gnu/*-zephyr-*" > /dev/null
}

url_exists() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsIL -o /dev/null "$1"
  else
    wget -q --spider "$1"
  fi
}

for CANDIDATE in "${ZEPHYR_SDK_INSTALL_DIR:-}" \
                 "${INSTALL_DIR}/zephyr-sdk-${SDK_VERSION}" \
                 "/opt/toolchains/zephyr-sdk-${SDK_VERSION}"; do
  if sdk_has_toolchains "${CANDIDATE}"; then
    echo "Reusing Zephyr SDK ${SDK_VERSION} at ${CANDIDATE}" >&2
    "${CANDIDATE}/setup.sh" -c >&2
    echo "${CANDIDATE}"
    exit 0
  fi
done

SDK_DIR="${INSTALL_DIR}/zephyr-sdk-${SDK_VERSION}"
SDK_BASE="https://github.com/zephyrproject-rtos/sdk-ng/releases/download/v${SDK_VERSION}"

# 0.16/0.17 ship one full bundle; 1.0 split it and renamed the GNU half.
SDK_URL=""
for NAME in "zephyr-sdk-${SDK_VERSION}_linux-x86_64.tar.xz" \
            "zephyr-sdk-${SDK_VERSION}_linux-x86_64_gnu.tar.xz"; do
  if url_exists "${SDK_BASE}/${NAME}"; then
    SDK_URL="${SDK_BASE}/${NAME}"
    break
  fi
done

if [[ -z "${SDK_URL}" ]]; then
  echo "No full Zephyr SDK bundle published for ${SDK_VERSION}" >&2
  exit 1
fi

echo "Installing Zephyr SDK ${SDK_VERSION} from ${SDK_URL}" >&2
mkdir -p "${INSTALL_DIR}"
# Stream into tar so the ~2G archive never sits on disk beside its ~7G expansion.
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "${SDK_URL}" | tar -C "${INSTALL_DIR}" -xJ
else
  wget -qO- "${SDK_URL}" | tar -C "${INSTALL_DIR}" -xJ
fi

if ! sdk_has_toolchains "${SDK_DIR}"; then
  echo "Zephyr SDK at ${SDK_DIR} has no toolchains" >&2
  exit 1
fi

"${SDK_DIR}/setup.sh" -c >&2
echo "${SDK_DIR}"
