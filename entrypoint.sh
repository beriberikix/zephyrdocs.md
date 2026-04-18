#!/bin/bash
set -euo pipefail

DOC_DIR="/docs/zephyrproject/zephyr/doc"
BUILD_DIR="${DOC_DIR}/_build"
OUTPUT_DIR="/output"

# Build cmake flags
CMAKE_EXTRA_ARGS=()
if [[ "${DT_TURBO_MODE:-0}" == "1" ]]; then
  CMAKE_EXTRA_ARGS+=("-DDT_TURBO_MODE=1")
  echo ":: DT_TURBO_MODE enabled — skipping devicetree bindings"
fi
if [[ "${HW_FEATURES_TURBO_MODE:-0}" == "1" ]]; then
  CMAKE_EXTRA_ARGS+=("-DHW_FEATURES_TURBO_MODE=1")
  echo ":: HW_FEATURES_TURBO_MODE enabled — skipping HW features index"
fi
if [[ -n "${HW_FEATURES_VENDOR_FILTER:-}" ]]; then
  CMAKE_EXTRA_ARGS+=("-DHW_FEATURES_VENDOR_FILTER=${HW_FEATURES_VENDOR_FILTER}")
  echo ":: HW_FEATURES_VENDOR_FILTER=${HW_FEATURES_VENDOR_FILTER}"
fi

# Default target
if [[ $# -eq 0 ]]; then
  set -- html
fi

# Configure (once)
echo ":: Configuring build with cmake..."
cmake -GNinja -B"${BUILD_DIR}" "${CMAKE_EXTRA_ARGS[@]+"${CMAKE_EXTRA_ARGS[@]}"}" "${DOC_DIR}"

# sphinx-llm spawns a markdown subprocess using app.srcdir (_build/src) as
# its source dir, but Zephyr keeps conf.py in the original doc dir and passes
# it via -c. Create a stripped conf.py in srcdir that removes doxygen-related
# extensions (they crash without the full build environment) and fixes paths.
mkdir -p "${BUILD_DIR}/src"
python3 - "${DOC_DIR}/conf.py" "${BUILD_DIR}/src/conf.py" << 'PYEOF'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    text = f.read()

# Fix ZEPHYR_BASE: __file__ will be in _build/src/, needs to point 3 parents up
text = text.replace(
    "ZEPHYR_BASE = Path(__file__).resolve().parents[1]",
    "ZEPHYR_BASE = Path(__file__).resolve().parents[3]",
)

# Remove doxygen extensions from the extensions list
for ext in ["zephyr.doxyrunner", "zephyr.doxybridge", "zephyr.doxytooltip", "zephyr.api_overview"]:
    text = re.sub(rf'^\s*"{re.escape(ext)}",?\n', '', text, flags=re.MULTILINE)

# Remove doxyrunner config block (doxyrunner_doxygen through DOXYGEN_SITEMAP_URL)
text = re.sub(
    r'^# -- Options for zephyr\.doxyrunner.*?^os\.environ\["DOXYGEN_SITEMAP_URL"\].*?\n',
    '', text, flags=re.MULTILINE | re.DOTALL,
)

# Remove doxybridge config line
text = re.sub(
    r'^# -- Options for zephyr\.doxybridge.*?^doxybridge_projects.*?\n',
    '', text, flags=re.MULTILINE | re.DOTALL,
)

# Remove api_overview_doxygen references
text = re.sub(r'^# -- Options for zephyr\.api_overview.*?\n', '', text, flags=re.MULTILINE)
text = re.sub(r'^api_overview_.*?\n', '', text, flags=re.MULTILINE)

with open(dst, 'w') as f:
    f.write(text)
PYEOF

cleanup_llm_output() {
  local html_dir="$1"

  if [[ ! -d "${html_dir}" ]]; then
  return
  fi

  if ! find "${html_dir}" -name '*.html.md' -print -quit | grep -q .; then
  return
  fi

  echo ":: Normalizing sphinx-llm markdown output"
  python3 - "${html_dir}" <<'PYEOF'
from pathlib import Path
import re
import sys

html_dir = Path(sys.argv[1])
md_files = sorted(html_dir.rglob("*.html.md"))

if not md_files:
  raise SystemExit(0)

COMMENT_RE = re.compile(r"<!--.*?-->", re.DOTALL)
SCRIPT_RE = re.compile(r"<script\b.*?</script>", re.IGNORECASE | re.DOTALL)
STYLE_RE = re.compile(r"<style\b.*?</style>", re.IGNORECASE | re.DOTALL)
ANCHOR_RE = re.compile(r"^\s*<a\b[^>]*>\s*</a>\s*$", re.IGNORECASE)
TAG_RE = re.compile(r"<[^>]+>")
WS_RE = re.compile(r"\s+")
BULLET_START_RE = re.compile(r"^(\s*)\*\s+")
INLINE_BULLET_RE = re.compile(r"(?<!\n)\s+\*\s+(?=(?:\[|[A-Za-z0-9`]))")


def sort_key(path: Path) -> tuple[int, str]:
  rel = path.relative_to(html_dir).as_posix()
  return (0 if rel == "index.html.md" else 1, rel)


def clean_markdown(text: str) -> str:
  text = COMMENT_RE.sub("", text)
  text = SCRIPT_RE.sub("", text)
  text = STYLE_RE.sub("", text)

  # Normalize markdown lists so downstream llms.txt generation sees a stable
  # structure even when the markdown builder emits '*' bullets inline.
  text = INLINE_BULLET_RE.sub("\n- ", text)

  cleaned_lines = []
  blank_run = 0

  for raw_line in text.splitlines():
    line = raw_line.rstrip()
    if ANCHOR_RE.match(line):
      continue

    line = BULLET_START_RE.sub(r"\1- ", line)

    if line.strip():
      blank_run = 0
      cleaned_lines.append(line)
    else:
      blank_run += 1
      if blank_run <= 1:
        cleaned_lines.append("")

  cleaned = "\n".join(cleaned_lines).strip()
  return f"{cleaned}\n" if cleaned else ""


def extract_title(text: str, path: Path) -> str:
  for raw_line in text.splitlines():
    line = raw_line.strip()
    if line.startswith("#"):
      return line.lstrip("#").strip()
  return path.stem.replace(".html", "").replace("_", " ").title()


def normalize_text(line: str) -> str:
  line = TAG_RE.sub("", line)
  return WS_RE.sub(" ", line).strip()


def extract_description(text: str) -> str:
  for raw_line in text.splitlines():
    line = raw_line.strip()
    if not line:
      continue
    if line.startswith("#"):
      continue
    if line.startswith(("* ", "- ")):
      continue
    if line.startswith(".."):
      continue

    line = normalize_text(line)
    if not line:
      continue
    if len(line) < 20:
      continue

    return f"{line[:100]}..." if len(line) > 100 else line

  return "Page content"


md_files.sort(key=sort_key)
cleaned_by_path: dict[Path, str] = {}

for path in md_files:
  cleaned = clean_markdown(path.read_text(encoding="utf-8"))
  path.write_text(cleaned, encoding="utf-8")
  cleaned_by_path[path] = cleaned

llms_path = html_dir / "llms.txt"
with llms_path.open("w", encoding="utf-8") as llms_file:
  llms_file.write("# Zephyr Project\n\n")
  llms_file.write("> Zephyr Project Documentation\n\n\n")
  llms_file.write("2015-2026 Zephyr Project members and individual contributors\n\n")
  llms_file.write("## Pages\n\n")

  for path in md_files:
    rel_path = path.relative_to(html_dir).as_posix()
    cleaned = cleaned_by_path[path]
    title = extract_title(cleaned, path)
    desc = extract_description(cleaned)
    llms_file.write(f"- [{title}]({rel_path}): {desc}\n")

llms_full_path = html_dir / "llms-full.txt"
with llms_full_path.open("w", encoding="utf-8") as llms_full_file:
  for path in md_files:
    rel_path = path.relative_to(html_dir).as_posix()
    cleaned = cleaned_by_path[path].rstrip()
    llms_full_file.write(f"# {rel_path}\n\n{cleaned}\n\n")
PYEOF
}

export_markdown_bundle() {
  local html_dir="$1"
  local output_dir="$2"
  local repo_root="$3"
  local build_src_dir="$4"
  local markdown_dir="${output_dir}/markdown"
  local markdown_tar="${output_dir}/markdown.tar.gz"

  if [[ ! -d "${html_dir}" ]]; then
    return
  fi

  echo ":: Exporting markdown-only output to ${markdown_dir}"
  rm -rf "${markdown_dir}" "${markdown_tar}"
  mkdir -p "${markdown_dir}"

    python3 - "${html_dir}" "${markdown_dir}" "${repo_root}" "${build_src_dir}" <<'PYEOF'
  from os import path as ospath
from pathlib import Path
  import re
import shutil
import sys

html_dir = Path(sys.argv[1])
markdown_dir = Path(sys.argv[2])
  repo_root = Path(sys.argv[3])
  build_src_dir = Path(sys.argv[4])

  copied_assets: dict[Path, Path] = {}
  page_files: list[Path] = []

  MD_IMAGE_RE = re.compile(r'!\[([^\]]*)\]\(([^)\s]+)([^)]*)\)')
  HTML_IMAGE_RE = re.compile(r'(<img\b[^>]*?\bsrc=["\'])([^"\']+)(["\'])', re.IGNORECASE)


  def is_external(ref: str) -> bool:
    return ref.startswith(("http://", "https://", "data:", "mailto:", "#"))


  def normalize_relpath(target: Path, from_dir: Path) -> str:
    return Path(ospath.relpath(target, from_dir)).as_posix()


  def candidate_paths(ref: str, md_rel: Path) -> list[Path]:
    md_dir_html = html_dir / md_rel.parent
    md_dir_build = build_src_dir / md_rel.parent
    candidates = [
      md_dir_html / ref,
      md_dir_build / ref,
      html_dir / ref,
      build_src_dir / ref,
      repo_root / ref,
      repo_root / "doc" / ref,
    ]

    trimmed = ref
    while trimmed.startswith("../"):
      trimmed = trimmed[3:]
      if not trimmed:
        break
      candidates.extend(
        [
          html_dir / trimmed,
          build_src_dir / trimmed,
          repo_root / trimmed,
          repo_root / "doc" / trimmed,
        ]
      )

    if trimmed.startswith("./"):
      trimmed = trimmed[2:]
      if trimmed:
        candidates.extend(
          [
            html_dir / trimmed,
            build_src_dir / trimmed,
            repo_root / trimmed,
            repo_root / "doc" / trimmed,
          ]
        )

    deduped = []
    seen = set()
    for candidate in candidates:
      try:
        key = candidate.resolve(strict=False)
      except OSError:
        key = candidate
      if key in seen:
        continue
      seen.add(key)
      deduped.append(candidate)
    return deduped


  def resolve_asset(ref: str, md_rel: Path) -> Path | None:
    clean_ref = ref.split("?", 1)[0].split("#", 1)[0]
    if not clean_ref or is_external(clean_ref):
      return None

    for candidate in candidate_paths(clean_ref, md_rel):
      if candidate.is_file():
        return candidate.resolve()
    return None


  def target_for_asset(asset: Path) -> Path:
    for base in (repo_root, build_src_dir, html_dir):
      try:
        rel = asset.relative_to(base)
        return markdown_dir / rel
      except ValueError:
        continue
    return markdown_dir / "_assets" / asset.name


  def ensure_asset(asset: Path) -> Path:
    existing = copied_assets.get(asset)
    if existing is not None:
      return existing

    target = target_for_asset(asset)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(asset, target)
    copied_assets[asset] = target
    return target


  def rewrite_images(text: str, md_rel: Path) -> str:
    bundle_file = markdown_dir / md_rel
    bundle_dir = bundle_file.parent

    def replace_md(match: re.Match[str]) -> str:
      alt_text, ref, suffix = match.groups()
      asset = resolve_asset(ref, md_rel)
      if asset is None:
        return match.group(0)
      target = ensure_asset(asset)
      rel_ref = normalize_relpath(target, bundle_dir)
      return f"![{alt_text}]({rel_ref}{suffix})"

    def replace_html(match: re.Match[str]) -> str:
      prefix, ref, suffix = match.groups()
      asset = resolve_asset(ref, md_rel)
      if asset is None:
        return match.group(0)
      target = ensure_asset(asset)
      rel_ref = normalize_relpath(target, bundle_dir)
      return f"{prefix}{rel_ref}{suffix}"

    text = MD_IMAGE_RE.sub(replace_md, text)
    text = HTML_IMAGE_RE.sub(replace_html, text)
    return text


  def sort_key(path: Path) -> tuple[int, str]:
    rel = path.relative_to(markdown_dir).as_posix()
    return (0 if rel == "index.html.md" else 1, rel)


  for src in sorted(html_dir.rglob("*.md")):
    if not src.is_file():
      continue

    rel_path = src.relative_to(html_dir)
    dst = markdown_dir / rel_path
    dst.parent.mkdir(parents=True, exist_ok=True)

    rewritten = rewrite_images(src.read_text(encoding="utf-8"), rel_path)
    dst.write_text(rewritten, encoding="utf-8")
    page_files.append(dst)

  llms_src = html_dir / "llms.txt"
  if llms_src.is_file():
    (markdown_dir / "llms.txt").write_text(llms_src.read_text(encoding="utf-8"), encoding="utf-8")

  page_files.sort(key=sort_key)
  with (markdown_dir / "llms-full.txt").open("w", encoding="utf-8") as llms_full_file:
    for page in page_files:
      rel_path = page.relative_to(markdown_dir).as_posix()
      cleaned = page.read_text(encoding="utf-8").rstrip()
      llms_full_file.write(f"# {rel_path}\n\n{cleaned}\n\n")
PYEOF

  tar -czf "${markdown_tar}" -C "${output_dir}" markdown
  echo ":: Created markdown archive ${markdown_tar}"
}

# Build each requested target
for target in "$@"; do
  echo ":: Building target: ${target}"
  # Sphinx may return non-zero due to warnings treated as errors (e.g. Doxygen
  # \file ambiguity). The HTML/PDF output is still fully generated in that case,
  # so we capture the exit code and warn rather than abort.
  if ! ninja -C "${BUILD_DIR}" "${target}"; then
    echo ":: WARNING: ninja target '${target}' exited with non-zero status (likely Sphinx warnings)"
  fi
done

cleanup_llm_output "${BUILD_DIR}/html"

# Copy output
mkdir -p "${OUTPUT_DIR}"

if [[ -d "${BUILD_DIR}/html" ]]; then
  echo ":: Copying HTML output to ${OUTPUT_DIR}/html"
  cp -a "${BUILD_DIR}/html" "${OUTPUT_DIR}/html"
  echo "   $(du -sh "${OUTPUT_DIR}/html" | cut -f1) total"
  export_markdown_bundle "${BUILD_DIR}/html" "${OUTPUT_DIR}" "/docs/zephyrproject/zephyr" "${BUILD_DIR}/src"
fi

if [[ -d "${BUILD_DIR}/latex" && -f "${BUILD_DIR}/latex/zephyr.pdf" ]]; then
  echo ":: Copying PDF output to ${OUTPUT_DIR}/pdf"
  mkdir -p "${OUTPUT_DIR}/pdf"
  cp -a "${BUILD_DIR}/latex/zephyr.pdf" "${OUTPUT_DIR}/pdf/"
  echo "   $(du -sh "${OUTPUT_DIR}/pdf/zephyr.pdf" | cut -f1) total"
fi

echo ":: Done"
