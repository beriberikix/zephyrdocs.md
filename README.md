# zdocs

`zdocs` builds `sphinx-llm` markdown bundles for Zephyr documentation and publishes them as tarball artifacts. The repository now centers on a `workflow_dispatch` GitHub Action with an inline matrix of upstream Zephyr refs, while keeping a Docker-backed local path for reproducing the same output.

## GitHub Action

The workflow in `.github/workflows/publish-markdown-tarballs.yml` runs one matrix job per Zephyr target and uploads one tarball artifact per job.

Manual runs can execute either all configured targets or one selected target through the `target` input on `workflow_dispatch`. Use a single target during troubleshooting so failures stay isolated to one repo/ref at a time.

Each matrix entry defines:

- the Zephyr repository URL
- the Zephyr ref to build
- a repo slug and ref slug used in cache keys and artifact names

Each bundle carries a `manifest.json` at its root describing what it is:

```json
{
  "schema": 1,
  "version": "v4.4.0",
  "zephyr_repo": "https://github.com/zephyrproject-rtos/zephyr",
  "zephyr_ref": "v4.4.0",
  "docs_base_url": "https://docs.zephyrproject.org/4.4.0",
  "page_count": 2364,
  "pages_root": "."
}
```

Consumers should read the version from there rather than parsing it out of
the artifact filename or the release tag.

Artifact filenames are distinguishable by design:

```text
<repo-slug>-<ref-slug>-markdown.tar.gz
```

The workflow is optimized for repeated runs:

- Python packages are cached per target and per checked-out Zephyr `doc/requirements.txt`
- the west workspace is cached per repo/ref so repeated runs only need to fetch the requested revision
- the workflow uses a filtered `west update` with `-babblesim,-optional,-testing` to keep the checkout smaller while preserving the module layout Zephyr docs expect
- CI enables `DT_TURBO_MODE=1` and `HW_FEATURES_TURBO_MODE=1` by default so markdown tarball runs skip the slowest doc-generation paths

The two turbo modes skip generated content, which keeps a run to roughly 15
minutes but leaves visible gaps in the bundle:

| Input | Turbo skips | Effect on the bundle |
| --- | --- | --- |
| `devicetree_bindings` | `build/dts/api/bindings/**` | board pages link into these pages, so those links dangle |

Enabling `devicetree_bindings` adds roughly 2,700 binding pages, taking a
v4.2.0 bundle from about 2,400 pages to about 5,100, and takes longer to build.

`HW_FEATURES_TURBO_MODE` stays on. The per-board supported-hardware tables are
derived from each board's devicetree, harvested by configuring every board,
which needs target toolchains that neither the workflow nor the Docker image
provisions. Turning it off today only spends build time: the board pages still
show the feature legend with no table under it.
- `sphinx_llm.txt` is injected automatically for upstream Zephyr revisions that do not already enable markdown output

To add another target, append a new `include` entry to the inline matrix and add its slug to the `workflow_dispatch` `target` options.

## Local Docker build

Build the image:

```bash
docker build -t zdocs .
```

Without overrides, the image builds against `zephyrproject-rtos/zephyr` at `main`.

Override the source repo or ref when needed:

```bash
docker build \
  --build-arg ZEPHYR_REPO=https://github.com/zephyrproject-rtos/zephyr \
  --build-arg ZEPHYR_VERSION=v4.4.0 \
  -t zdocs .
```

Run the markdown-only export:

```bash
docker run \
  -e MARKDOWN_TARBALL_NAME=zephyrproject-rtos-zephyr-main-markdown.tar.gz \
  -v $(pwd)/output:/output \
  zdocs
```

The container produces:

- `output/markdown/` for the rewritten markdown tree
- `output/<name>.tar.gz` for the bundle artifact

Each run refreshes the markdown bundle in place and removes stale markdown-era outputs such as old tarballs or leftover `output/html/` and `output/pdf/` directories from earlier container runs.

Optional turbo-mode inputs still work during local builds:

```bash
docker run \
  -e DT_TURBO_MODE=1 \
  -e HW_FEATURES_TURBO_MODE=1 \
  -e HW_FEATURES_VENDOR_FILTER=vendor1,vendor2 \
  -v $(pwd)/output:/output \
  zdocs
```

## Direct script usage

The reusable scripts are:

- `scripts/setup-zephyr-workspace.sh` to create or refresh a minimal west workspace for a chosen repo/ref
- `scripts/build-markdown.sh` to configure Sphinx, normalize `sphinx-llm` output, rewrite asset links, and create the tarball

`scripts/setup-zephyr-workspace.sh` still supports a more aggressive `zephyr-only` mode for experimentation, but the workflow defaults to the filtered mode above because it is the safer choice for full documentation builds.

That split keeps the GitHub workflow and the local Docker path on the same build logic.
