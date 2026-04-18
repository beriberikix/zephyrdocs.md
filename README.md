# zdocs

`zdocs` builds `sphinx-llm` markdown bundles for Zephyr documentation and publishes them as tarball artifacts. The repository now centers on a `workflow_dispatch` GitHub Action with an inline matrix of Zephyr repositories and refs, while keeping a Docker-backed local path for reproducing the same output.

## GitHub Action

The workflow in `.github/workflows/publish-markdown-tarballs.yml` runs one matrix job per Zephyr target and uploads one tarball artifact per job.

Each matrix entry defines:

- the Zephyr repository URL
- the Zephyr ref to build
- a repo slug and ref slug used in cache keys and artifact names

Artifact filenames are distinguishable by design:

```text
<repo-slug>-<ref-slug>-markdown.tar.gz
```

The workflow is optimized for repeated runs:

- Python packages are cached through `actions/cache`
- the west workspace is cached per repo/ref so repeated runs only need to fetch the requested revision
- the workflow uses a filtered `west update` with `-babblesim,-optional,-testing` to keep the checkout smaller while preserving the module layout Zephyr docs expect
- `sphinx_llm.txt` is injected automatically for upstream Zephyr revisions that do not already enable markdown output

To add another target, append a new `include` entry to the inline matrix.

## Local Docker build

Build the image:

```bash
docker build -t zdocs .
```

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
  -e MARKDOWN_TARBALL_NAME=zephyrproject-rtos-zephyr-v4-4-0-markdown.tar.gz \
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
