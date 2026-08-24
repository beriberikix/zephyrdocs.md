#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: build-markdown.sh --zephyr-root PATH --output-dir PATH [options]

Options:
  --zephyr-root PATH      Path to the Zephyr repository root.
  --output-dir PATH       Directory that receives markdown/ and the tarball.
  --archive-name NAME     Output tarball filename. Defaults to markdown.tar.gz.
  --zephyr-repo URL       Source repository recorded in the bundle manifest.
  --zephyr-ref REF        Source ref recorded in the bundle manifest.
  --doc-version VERSION   Version recorded in each page's front matter, e.g.
                          v4.4.0. Front matter is only emitted when set.
  --docs-base-url URL     Published docs base for this ref, e.g.
                          https://docs.zephyrproject.org/4.4.0. When set,
                          image and other asset references are rewritten to
                          absolute URLs under it instead of being bundled.
  -h, --help              Show this help text.
EOF
}

ZEPHYR_ROOT=""
OUTPUT_DIR=""
ARCHIVE_NAME="markdown.tar.gz"
DOCS_BASE_URL=""
DOC_VERSION=""
ZEPHYR_REPO=""
ZEPHYR_REF=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --zephyr-root)
      ZEPHYR_ROOT="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --archive-name)
      ARCHIVE_NAME="$2"
      shift 2
      ;;
    --docs-base-url)
      DOCS_BASE_URL="$2"
      shift 2
      ;;
    --doc-version)
      DOC_VERSION="$2"
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

if [[ -z "${ZEPHYR_ROOT}" || -z "${OUTPUT_DIR}" ]]; then
  usage >&2
  exit 1
fi

validate_archive_name() {
    case "$1" in
        ""|"."|".."|*/*|*\\*)
            echo "Archive name must be a filename within OUTPUT_DIR: $1" >&2
            exit 1
            ;;
    esac
}

validate_archive_name "${ARCHIVE_NAME}"

DOC_DIR="${ZEPHYR_ROOT}/doc"
BUILD_DIR="${DOC_DIR}/_build"
ARCHIVE_PATH="${OUTPUT_DIR}/${ARCHIVE_NAME}"

if [[ ! -d "${DOC_DIR}" ]]; then
  echo "Zephyr doc directory not found: ${DOC_DIR}" >&2
  exit 1
fi

reset_output_dir() {
    mkdir -p "${OUTPUT_DIR}"
    find "${OUTPUT_DIR}" -mindepth 1 -maxdepth 1 \
        \( -name markdown -o -name html -o -name pdf -o -name '*.tar.gz' \) \
        -exec rm -rf {} +
}

inject_sphinx_llm() {
  python3 - "${DOC_DIR}/conf.py" <<'PYEOF'
from pathlib import Path
import re
import sys

conf_path = Path(sys.argv[1])
text = conf_path.read_text(encoding="utf-8")

if '"sphinx_llm.txt"' in text or "'sphinx_llm.txt'" in text:
    raise SystemExit(0)

match = re.search(r"(extensions\s*=\s*\[)(.*?)(\n\])", text, re.DOTALL)
if match is None:
    raise SystemExit("Unable to find extensions list in conf.py")

text = text[:match.start(3)] + '\n    "sphinx_llm.txt",' + text[match.start(3):]
conf_path.write_text(text, encoding="utf-8")
PYEOF
}

prepare_markdown_conf() {
  mkdir -p "${BUILD_DIR}/src"
  python3 - "${DOC_DIR}/conf.py" "${BUILD_DIR}/src/conf.py" <<'PYEOF'
import re
import sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, encoding="utf-8") as handle:
    text = handle.read()

text = text.replace(
    "ZEPHYR_BASE = Path(__file__).resolve().parents[1]",
    "ZEPHYR_BASE = Path(__file__).resolve().parents[3]",
)

for ext in [
    "zephyr.doxyrunner",
    "zephyr.doxybridge",
    "zephyr.doxytooltip",
    "zephyr.api_overview",
]:
    text = re.sub(rf'^\s*"{re.escape(ext)}",?\n', '', text, flags=re.MULTILINE)

text = re.sub(
    r'^# -- Options for zephyr\.doxyrunner.*?^os\.environ\["DOXYGEN_SITEMAP_URL"\].*?\n',
    '',
    text,
    flags=re.MULTILINE | re.DOTALL,
)
text = re.sub(
    r'^# -- Options for zephyr\.doxybridge.*?^doxybridge_projects.*?\n',
    '',
    text,
    flags=re.MULTILINE | re.DOTALL,
)
text = re.sub(r'^# -- Options for zephyr\.api_overview.*?\n', '', text, flags=re.MULTILINE)
text = re.sub(r'^api_overview_.*?\n', '', text, flags=re.MULTILINE)

with open(dst, 'w', encoding="utf-8") as handle:
    handle.write(text)
PYEOF
}

cleanup_llm_output() {
  local html_dir="$1"

  if [[ ! -d "${html_dir}" ]]; then
    echo "HTML build output not found: ${html_dir}" >&2
    exit 1
  fi

  echo ":: Normalizing sphinx-llm markdown output"
  python3 - "${html_dir}" <<'PYEOF'
from pathlib import Path
import html as html_lib
import re
import sys

html_dir = Path(sys.argv[1])
md_files = sorted(html_dir.rglob("*.html.md"))

if not md_files:
    raise SystemExit("sphinx-llm did not generate any .html.md files")

COMMENT_RE = re.compile(r"<!--.*?-->", re.DOTALL)
SCRIPT_RE = re.compile(r"<script\b.*?</script>", re.IGNORECASE | re.DOTALL)
STYLE_RE = re.compile(r"<style\b.*?</style>", re.IGNORECASE | re.DOTALL)
HTML_IMAGE_RE = re.compile(r"<img\b([^>]*?)\bsrc=[\"']([^\"']+)[\"']([^>]*)>", re.IGNORECASE | re.DOTALL)
HTML_LINK_RE = re.compile(r"<a\b([^>]*?)\bhref=[\"']([^\"']+)[\"']([^>]*)>(.*?)</a>", re.IGNORECASE | re.DOTALL)
HEADING_RE = re.compile(r"<h([1-6])\b[^>]*>(.*?)</h\1>", re.IGNORECASE | re.DOTALL)
LINE_BREAK_RE = re.compile(r"<br\s*/?>", re.IGNORECASE)
LIST_ITEM_OPEN_RE = re.compile(r"<li\b[^>]*>", re.IGNORECASE)
LIST_ITEM_CLOSE_RE = re.compile(r"</li>", re.IGNORECASE)
BLOCK_TAG_RE = re.compile(
    r"</?(?:main|section|article|header|footer|nav|div|p|ul|ol|figure|figcaption|table|thead|tbody|tr|td|th)\b[^>]*>",
    re.IGNORECASE,
)
NOSCRIPT_TAG_RE = re.compile(r"</?noscript\b[^>]*>", re.IGNORECASE)
GENERIC_TAG_RE = re.compile(r"<[^>]+>")
WS_RE = re.compile(r"\s+")
FENCE_RE = re.compile(r"(^```.*?^```[ \t]*$)", re.MULTILINE | re.DOTALL)
BLANK_LINE_RE = re.compile(r"\n{3,}")
BULLET_START_RE = re.compile(r"^(\s*)\*\s+")
INLINE_BULLET_RE = re.compile(r"(?<!\n)\s+\*\s+(?=(?:\[|[A-Za-z0-9`]))")
ADJACENT_IMAGE_RE = re.compile(r"\)(?=!\[)")


def bundle_name(rel: str) -> str:
    """sphinx-llm writes "<page>.html.md"; the bundle ships "<page>.md"."""
    return rel[: -len(".html.md")] + ".md" if rel.endswith(".html.md") else rel


def sort_key(path: Path) -> tuple[int, str]:
    rel = path.relative_to(html_dir).as_posix()
    return (0 if rel == "index.html.md" else 1, rel)


def plain_text(fragment: str) -> str:
    fragment = LINE_BREAK_RE.sub("\n", fragment)
    fragment = LIST_ITEM_OPEN_RE.sub("- ", fragment)
    fragment = LIST_ITEM_CLOSE_RE.sub("\n", fragment)
    fragment = BLOCK_TAG_RE.sub("\n", fragment)
    fragment = NOSCRIPT_TAG_RE.sub("\n", fragment)
    fragment = GENERIC_TAG_RE.sub("", fragment)
    fragment = html_lib.unescape(fragment)
    return WS_RE.sub(" ", fragment).strip()


def clean_fragment(text: str) -> str:
    text = COMMENT_RE.sub("", text)
    text = SCRIPT_RE.sub("", text)
    text = STYLE_RE.sub("", text)
    text = NOSCRIPT_TAG_RE.sub("\n", text)

    def replace_image(match: re.Match[str]) -> str:
        attrs = f"{match.group(1)} {match.group(3)}"
        alt_match = re.search(r'\balt=[\"\']([^\"\']*)[\"\']', attrs, re.IGNORECASE)
        alt_text = plain_text(alt_match.group(1)) if alt_match else "image"
        alt_text = alt_text or "image"
        return f"![{alt_text}]({match.group(2).strip()})"

    def replace_link(match: re.Match[str]) -> str:
        href = match.group(2).strip()
        label = plain_text(match.group(4))
        if not href:
            return label
        if not label:
            return href
        return f"[{label}]({href})"

    def replace_heading(match: re.Match[str]) -> str:
        level = int(match.group(1))
        label = plain_text(match.group(2))
        if not label:
            return "\n"
        return f"\n\n{'#' * level} {label}\n\n"

    text = HTML_IMAGE_RE.sub(replace_image, text)
    text = HTML_LINK_RE.sub(replace_link, text)
    text = HEADING_RE.sub(replace_heading, text)
    text = LINE_BREAK_RE.sub("\n", text)
    text = LIST_ITEM_OPEN_RE.sub("\n- ", text)
    text = LIST_ITEM_CLOSE_RE.sub("\n", text)
    text = BLOCK_TAG_RE.sub("\n", text)
    text = GENERIC_TAG_RE.sub("", text)
    text = html_lib.unescape(text)
    text = ADJACENT_IMAGE_RE.sub(")\n", text)
    text = INLINE_BULLET_RE.sub("\n- ", text)

    cleaned_lines = []
    blank_run = 0

    for raw_line in text.splitlines():
        line = raw_line.rstrip()
        line = BULLET_START_RE.sub(r"\1- ", line)
        line = re.sub(r"\s{2,}", " ", line).rstrip()

        if line.strip():
            blank_run = 0
            cleaned_lines.append(line)
        else:
            blank_run += 1
            if blank_run <= 1:
                cleaned_lines.append("")

    cleaned = "\n".join(cleaned_lines).strip()
    cleaned = BLANK_LINE_RE.sub("\n\n", cleaned)
    return f"{cleaned}\n" if cleaned else ""


def clean_markdown(text: str) -> str:
    parts = FENCE_RE.split(text)
    cleaned_parts = []

    for index, part in enumerate(parts):
        cleaned_parts.append(part if index % 2 else clean_fragment(part))

    cleaned = "".join(cleaned_parts).strip()
    cleaned = BLANK_LINE_RE.sub("\n\n", cleaned)
    return f"{cleaned}\n" if cleaned else ""


def extract_title(text: str, path: Path) -> str:
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if line.startswith("#"):
            return line.lstrip("#").strip()
    return path.stem.replace(".html", "").replace("_", " ").title()


def normalize_text(line: str) -> str:
    line = GENERIC_TAG_RE.sub("", line)
    line = html_lib.unescape(line)
    return WS_RE.sub(" ", line).strip()


def extract_description(text: str) -> str:
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line.startswith("#"):
            continue
        if line.startswith(("* ", "- ", "..", "![", "|")):
            continue

        line = normalize_text(line)
        if not line:
            continue
        if len(line) < 20:
            continue

        return f"{line[:100]}..." if len(line) > 100 else line

    return "Page content"


md_files.sort(key=sort_key)
cleaned_by_path = {}

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
        rel_path = bundle_name(path.relative_to(html_dir).as_posix())
        cleaned = cleaned_by_path[path]
        title = extract_title(cleaned, path)
        desc = extract_description(cleaned)
        llms_file.write(f"- [{title}]({rel_path}): {desc}\n")

llms_full_path = html_dir / "llms-full.txt"
with llms_full_path.open("w", encoding="utf-8") as llms_full_file:
    for path in md_files:
        rel_path = bundle_name(path.relative_to(html_dir).as_posix())
        cleaned = cleaned_by_path[path].rstrip()
        llms_full_file.write(f"# {rel_path}\n\n{cleaned}\n\n")
PYEOF
}

export_markdown_bundle() {
  local html_dir="$1"
  local output_dir="$2"
  local repo_root="$3"
  local build_src_dir="$4"
  local archive_path="$5"
  local markdown_dir="${output_dir}/markdown"

  echo ":: Exporting markdown-only output to ${markdown_dir}"
  rm -rf "${markdown_dir}" "${archive_path}"
  mkdir -p "${markdown_dir}"

    python3 - "${html_dir}" "${markdown_dir}" "${repo_root}" "${build_src_dir}" "${DOCS_BASE_URL}" "${DOC_VERSION}" "${ZEPHYR_REPO}" "${ZEPHYR_REF}" <<'PYEOF'
from os import path as ospath
from pathlib import Path, PurePosixPath
import json
import re
import shutil
import sys

html_dir = Path(sys.argv[1])
markdown_dir = Path(sys.argv[2])
repo_root = Path(sys.argv[3])
build_src_dir = Path(sys.argv[4])
docs_base_url = (sys.argv[5] if len(sys.argv) > 5 else "").rstrip("/")
doc_version = sys.argv[6] if len(sys.argv) > 6 else ""
zephyr_repo = sys.argv[7] if len(sys.argv) > 7 else ""
zephyr_ref = sys.argv[8] if len(sys.argv) > 8 else ""
approved_bases = [
    html_dir.resolve(),
    build_src_dir.resolve(),
    (repo_root / "doc").resolve(),
    repo_root.resolve(),
]

copied_assets = {}
page_files = []

MD_IMAGE_RE = re.compile(r'!\[([^\]]*)\]\(([^)\s]+)([^)]*)\)')
MD_LINK_RE = re.compile(r'(?<!!)\[([^\]]+)\]\(([^)\s]+)([^)]*)\)')
HTML_IMAGE_RE = re.compile(r'(<img\b[^>]*?\bsrc=["\'])([^"\']+)(["\'])', re.IGNORECASE)


def is_external(ref: str) -> bool:
    return ref.startswith(("http://", "https://", "data:", "mailto:", "#"))


def docs_asset_url(ref: str, md_rel: Path) -> str | None:
    """Absolute URL for an asset reference, relative to the published docs.

    Sphinx emits asset references relative to the page, e.g.
    "../../../../_images/board.jpg". Those files are not carried in this
    bundle, so a relative path resolves to nothing; point at the published
    copy instead, which costs no bundle size.
    """
    if not docs_base_url or is_external(ref):
        return None

    target, suffix = split_ref(ref)
    if not target:
        return None

    page_relative = ospath.normpath(ospath.join(md_rel.parent.as_posix(), target))
    root_relative = ospath.normpath(target)

    # Prefer whichever spelling names a file the build actually produced.
    for candidate in (page_relative, root_relative):
        if candidate.startswith("..") or candidate in ("", "."):
            continue
        if (html_dir / candidate).exists():
            return f"{docs_base_url}/{PurePosixPath(candidate).as_posix()}{suffix}"

    if page_relative.startswith("..") or page_relative in ("", "."):
        return None

    return f"{docs_base_url}/{PurePosixPath(page_relative).as_posix()}{suffix}"


def yaml_scalar(value: str) -> str:
    """Quote a front-matter value only when YAML would otherwise misread it."""
    if value and not any(c in value for c in ':#\'"\n') and value.strip() == value:
        return value
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def front_matter(rel: Path) -> str:
    """Provenance header, so a retrieved page can be cited.

    Records the Zephyr version the page was built from, where it is published,
    and the path it came from. Emitted only when --doc-version is given.
    """
    if not doc_version:
        return ""

    original = rel.as_posix()
    if original.endswith(".html.md"):
        original = original[: -len(".md")]

    lines = [
        "---",
        f"version: {yaml_scalar(doc_version)}",
    ]
    if docs_base_url:
        lines.append(f"source_url: {yaml_scalar(f'{docs_base_url}/{original}')}")
    lines.append(f"original_path: {yaml_scalar(original)}")
    lines.append("---")
    return "\n".join(lines) + "\n\n"


def bundle_page(rel: Path) -> Path:
    """sphinx-llm writes "<page>.html.md"; the bundle ships "<page>.md".

    sphinx-llm also emits cross-references as "<page>.md", so keeping the
    double extension on disk left every internal link pointing at a file that
    was never written.
    """
    text = rel.as_posix()
    if text.endswith(".html.md"):
        return Path(text[: -len(".html.md")] + ".md")
    return rel


def split_ref(ref: str) -> tuple[str, str]:
    match = re.match(r'([^?#]*)(.*)', ref)
    if match is None:
        return ref, ""
    return match.group(1), match.group(2)


def normalize_site_ref(ref: str) -> str:
    if ref.startswith("/latest/"):
        return ref[len("/latest/"):].lstrip("/")
    if ref.startswith("/"):
        return ref.lstrip("/")
    return ref


def sanitize_workspace_ref(ref: str):
    normalized = normalize_site_ref(ref)
    if not normalized:
        return None

    pure = PurePosixPath(normalized)
    if pure.is_absolute():
        return None
    if normalized in ("", "."):
        return None
    if any(part == ".." for part in pure.parts):
        return None

    return pure.as_posix()


def normalize_relpath(target: Path, from_dir: Path) -> str:
    return Path(ospath.relpath(target, from_dir)).as_posix()


def dedupe_paths(paths):
    deduped = []
    seen = set()

    for candidate in paths:
        try:
            key = candidate.resolve(strict=False)
        except OSError:
            key = candidate
        if key in seen:
            continue
        seen.add(key)
        deduped.append(candidate)

    return deduped


def is_under_approved_base(candidate: Path) -> bool:
    for base in approved_bases:
        try:
            candidate.relative_to(base)
            return True
        except ValueError:
            continue

    return False


def candidate_paths(ref: str, md_rel: Path):
    safe_ref = sanitize_workspace_ref(ref)
    if safe_ref is None:
        return []

    md_dir_html = html_dir / md_rel.parent
    md_dir_build = build_src_dir / md_rel.parent
    candidates = [
        md_dir_html / safe_ref,
        md_dir_build / safe_ref,
        html_dir / safe_ref,
        build_src_dir / safe_ref,
        repo_root / "doc" / safe_ref,
        repo_root / safe_ref,
    ]

    basename = Path(safe_ref).name
    if basename:
        candidates.extend(
            [
                html_dir / "_images" / basename,
                build_src_dir / "_images" / basename,
                repo_root / "doc" / "_static" / basename,
                repo_root / "doc" / basename,
            ]
        )

    return dedupe_paths(candidates)


def resolve_asset(ref: str, md_rel: Path):
    clean_ref, _suffix = split_ref(ref)
    if not clean_ref or is_external(clean_ref):
        return None

    for candidate in candidate_paths(clean_ref, md_rel):
        if candidate.is_file():
            resolved = candidate.resolve()
            if is_under_approved_base(resolved):
                return resolved

    return None


def target_for_asset(asset: Path) -> Path:
    for base in (html_dir, build_src_dir, repo_root / "doc", repo_root):
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


def doc_candidates(ref: str, md_rel: Path):
    clean_ref = normalize_site_ref(ref)
    base_dir = md_rel.parent.as_posix()
    raw_candidates = []

    if ref.startswith("/"):
        raw_candidates.append(clean_ref)
    else:
        raw_candidates.append(ospath.normpath(ospath.join(base_dir, ref)))
        if clean_ref != ref:
            raw_candidates.append(clean_ref)

    candidates = []
    seen = set()
    for candidate in raw_candidates:
        candidate = candidate.rstrip("/")
        if candidate in ("", "."):
            candidate = "index.html"
        if candidate in seen:
            continue
        seen.add(candidate)
        candidates.append(Path(candidate))

    return candidates


def resolve_doc_target(ref: str, md_rel: Path):
    clean_ref, suffix = split_ref(ref)
    if not clean_ref or is_external(clean_ref):
        return None

    for candidate in doc_candidates(clean_ref, md_rel):
        candidate_str = candidate.as_posix()

        if candidate.suffix == ".html" and (html_dir / candidate).is_file():
            return (markdown_dir / bundle_page(Path(f"{candidate_str}.md")), suffix)

        # sphinx-llm emits references as "<page>.md" while generating
        # "<page>.html.md", so look for the generated name too.
        if candidate.suffix == ".md":
            if (html_dir / candidate).is_file():
                # The reference may already be spelled "<page>.html.md"; the
                # bundle ships it renamed either way.
                return (markdown_dir / bundle_page(candidate), suffix)

            generated = Path(f"{candidate_str[: -len('.md')]}.html.md")
            if (html_dir / generated).is_file():
                return (markdown_dir / bundle_page(generated), suffix)

        if candidate.suffix == "":
            direct_page = html_dir / Path(f"{candidate_str}.html")
            if direct_page.is_file():
                return (markdown_dir / bundle_page(Path(f"{candidate_str}.html.md")), suffix)

            index_page = html_dir / candidate / "index.html"
            if index_page.is_file():
                return (markdown_dir / candidate / "index.md", suffix)

    return None


def rewrite_markdown(text: str, md_rel: Path) -> str:
    bundle_dir = (markdown_dir / md_rel).parent

    def replace_md_image(match: re.Match[str]) -> str:
        alt_text, ref, suffix = match.groups()
        asset = resolve_asset(ref, md_rel)
        if asset is None:
            external = docs_asset_url(ref, md_rel)
            if external is not None:
                return f"![{alt_text}]({external}{suffix})"
            return match.group(0)
        target = ensure_asset(asset)
        rel_ref = normalize_relpath(target, bundle_dir)
        return f"![{alt_text}]({rel_ref}{suffix})"

    def replace_html_image(match: re.Match[str]) -> str:
        prefix, ref, suffix = match.groups()
        asset = resolve_asset(ref, md_rel)
        if asset is None:
            external = docs_asset_url(ref, md_rel)
            if external is not None:
                return f"{prefix}{external}{suffix}"
            return match.group(0)
        target = ensure_asset(asset)
        rel_ref = normalize_relpath(target, bundle_dir)
        return f"{prefix}{rel_ref}{suffix}"

    def replace_md_link(match: re.Match[str]) -> str:
        label, ref, suffix = match.groups()
        resolved = resolve_doc_target(ref, md_rel)
        if resolved is None:
            clean_ref, _ = split_ref(ref)
            if clean_ref and PurePosixPath(clean_ref).suffix.lower() not in ("", ".md", ".html"):
                external = docs_asset_url(ref, md_rel)
                if external is not None:
                    return f"[{label}]({external}{suffix})"
            return match.group(0)
        target, anchor_suffix = resolved
        rel_ref = normalize_relpath(target, bundle_dir)
        return f"[{label}]({rel_ref}{anchor_suffix}{suffix})"

    text = MD_IMAGE_RE.sub(replace_md_image, text)
    text = HTML_IMAGE_RE.sub(replace_html_image, text)
    text = MD_LINK_RE.sub(replace_md_link, text)
    return text


def sort_key(path: Path) -> tuple[int, str]:
    rel = path.relative_to(markdown_dir).as_posix()
    return (0 if rel == "index.md" else 1, rel)


for src in sorted(html_dir.rglob("*.md")):
    if not src.is_file():
        continue

    rel_path = src.relative_to(html_dir)
    dst = markdown_dir / bundle_page(rel_path)
    dst.parent.mkdir(parents=True, exist_ok=True)

    rewritten = rewrite_markdown(src.read_text(encoding="utf-8"), rel_path)
    dst.write_text(front_matter(rel_path) + rewritten, encoding="utf-8")
    page_files.append(dst)

manifest = {
    "schema": 1,
    "version": doc_version,
    "zephyr_repo": zephyr_repo,
    "zephyr_ref": zephyr_ref,
    "docs_base_url": docs_base_url,
    "page_count": len(page_files),
    "pages_root": ".",
}
(markdown_dir / "manifest.json").write_text(
    json.dumps({k: v for k, v in manifest.items() if v != ""}, indent=2) + "\n",
    encoding="utf-8",
)

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

  tar -czf "${archive_path}" -C "${output_dir}" markdown
  echo ":: Created markdown archive ${archive_path}"
}

CMAKE_EXTRA_ARGS=()
if [[ "${DT_TURBO_MODE:-0}" == "1" ]]; then
  CMAKE_EXTRA_ARGS+=("-DDT_TURBO_MODE=1")
  echo ":: DT_TURBO_MODE enabled - skipping devicetree bindings"
fi
if [[ "${HW_FEATURES_TURBO_MODE:-0}" == "1" ]]; then
  CMAKE_EXTRA_ARGS+=("-DHW_FEATURES_TURBO_MODE=1")
  echo ":: HW_FEATURES_TURBO_MODE enabled - skipping HW features index"
fi
if [[ -n "${HW_FEATURES_VENDOR_FILTER:-}" ]]; then
  CMAKE_EXTRA_ARGS+=("-DHW_FEATURES_VENDOR_FILTER=${HW_FEATURES_VENDOR_FILTER}")
  echo ":: HW_FEATURES_VENDOR_FILTER=${HW_FEATURES_VENDOR_FILTER}"
fi

reset_output_dir
inject_sphinx_llm

echo ":: Configuring build with cmake..."
cmake_cmd=(cmake -GNinja -B"${BUILD_DIR}")
if [[ ${#CMAKE_EXTRA_ARGS[@]} -gt 0 ]]; then
    cmake_cmd+=("${CMAKE_EXTRA_ARGS[@]}")
fi
cmake_cmd+=("${DOC_DIR}")
"${cmake_cmd[@]}"
prepare_markdown_conf

echo ":: Building target: html"
if ! ninja -C "${BUILD_DIR}" html; then
  echo ":: WARNING: ninja target 'html' exited with non-zero status (likely Sphinx warnings)"
fi

cleanup_llm_output "${BUILD_DIR}/html"
export_markdown_bundle "${BUILD_DIR}/html" "${OUTPUT_DIR}" "${ZEPHYR_ROOT}" "${BUILD_DIR}/src" "${ARCHIVE_PATH}"

echo ":: Done"
