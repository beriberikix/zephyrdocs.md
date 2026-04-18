#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: setup-zephyr-workspace.sh --workspace-root PATH --zephyr-repo URL --zephyr-ref REF [options]

Options:
  --workspace-root PATH    Directory that will contain the west workspace.
  --zephyr-repo URL        Zephyr repository URL.
  --zephyr-ref REF         Branch, tag, or commit-ish to check out.
  --mode MODE              Workspace mode: zephyr-only or filtered. Defaults to zephyr-only.
  --group-filter FILTER    West manifest group filter for filtered mode.
  --project-filter FILTER  West manifest project filter for filtered mode.
  -h, --help               Show this help text.
EOF
}

WORKSPACE_ROOT=""
ZEPHYR_REPO=""
ZEPHYR_REF=""
MODE="zephyr-only"
GROUP_FILTER=""
PROJECT_FILTER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace-root)
      WORKSPACE_ROOT="$2"
      shift 2
      ;;
    --zephyr-repo)
      ZEPHYR_REPO="$2"
      shift 2
      ;;
    --zephyr-ref)
      ZEPHYR_REF="$2"
      shift 2
      ;;
    --mode)
      MODE="$2"
      shift 2
      ;;
    --group-filter)
      GROUP_FILTER="$2"
      shift 2
      ;;
    --project-filter)
      PROJECT_FILTER="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${WORKSPACE_ROOT}" || -z "${ZEPHYR_REPO}" || -z "${ZEPHYR_REF}" ]]; then
  usage >&2
  exit 1
fi

sync_manifest_repo() {
  (
    cd "${WORKSPACE_ROOT}/zephyr"
    git remote set-url origin "${ZEPHYR_REPO}"
    git fetch --depth=1 origin "${ZEPHYR_REF}"
    git checkout --force FETCH_HEAD
    git clean -ffdqx
  )
}

workspace_ready=0
if [[ -d "${WORKSPACE_ROOT}/.west" && -d "${WORKSPACE_ROOT}/zephyr/.git" ]]; then
  current_origin="$(git -C "${WORKSPACE_ROOT}/zephyr" remote get-url origin 2>/dev/null || true)"
  if [[ "${current_origin}" == "${ZEPHYR_REPO}" ]]; then
    workspace_ready=1
  fi
fi

if [[ "${workspace_ready}" != "1" ]]; then
  rm -rf "${WORKSPACE_ROOT}"
  mkdir -p "$(dirname "${WORKSPACE_ROOT}")"
  west init -m "${ZEPHYR_REPO}" --mr "${ZEPHYR_REF}" "${WORKSPACE_ROOT}"
fi

case "${MODE}" in
  zephyr-only)
    sync_manifest_repo
    ;;
  filtered)
    sync_manifest_repo
    (
      cd "${WORKSPACE_ROOT}"
      if [[ -n "${GROUP_FILTER}" ]]; then
        west config manifest.group-filter -- "${GROUP_FILTER}"
      fi
      if [[ -n "${PROJECT_FILTER}" ]]; then
        west config manifest.project-filter -- "${PROJECT_FILTER}"
      fi
      west update -n -o=--depth=1
    )
    ;;
  *)
    echo "Unsupported workspace mode: ${MODE}" >&2
    exit 1
    ;;
esac

(
  cd "${WORKSPACE_ROOT}"
  west zephyr-export
)

printf 'zephyr_root=%s\n' "${WORKSPACE_ROOT}/zephyr"
