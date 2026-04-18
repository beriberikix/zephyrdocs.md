# zdocs — Reproducible Zephyr Documentation Builder

Containerized build environment for the [Zephyr Project](https://docs.zephyrproject.org/) documentation, following the official [Documentation Generation](https://docs.zephyrproject.org/latest/contribute/documentation/generation.html) guide.

By default this project builds from the fork at `https://github.com/beriberikix/zephyr` on branch `docs/llms-txt`, which enables `sphinx-llm` output alongside the regular HTML documentation.

## Build the image

```bash
docker build -t zdocs .
```

To build docs from a different Zephyr repo or branch:

```bash
docker build \
  --build-arg ZEPHYR_REPO=https://github.com/zephyrproject-rtos/zephyr \
  --build-arg ZEPHYR_VERSION=v4.4.0 \
  -t zdocs .
```

## Generate documentation

HTML (default):

```bash
docker run -v $(pwd)/output:/output zdocs
```

PDF:

```bash
docker run -v $(pwd)/output:/output zdocs pdf
```

Both:

```bash
docker run -v $(pwd)/output:/output zdocs html pdf
```

### Turbo mode environment variables

For faster builds during iteration, you can skip expensive generation steps:

```bash
docker run \
  -e DT_TURBO_MODE=1 \
  -e HW_FEATURES_TURBO_MODE=1 \
  -v $(pwd)/output:/output \
  zdocs
```

To limit HW features to specific board vendors:

```bash
docker run \
  -e HW_FEATURES_VENDOR_FILTER=vendor1,vendor2 \
  -v $(pwd)/output:/output \
  zdocs
```

## View the output

After building, serve the HTML docs locally:

```bash
python3 -m http.server -d output/html
```

Then open http://localhost:8000 in your browser.

PDF output is at `output/pdf/zephyr.pdf`.

## Markdown output

The build also exports `sphinx-llm` artifacts:

- `output/html/llms.txt`
- `output/html/llms-full.txt`
- per-page markdown files under `output/html/**/*.html.md`

In addition, the entrypoint creates a markdown-only bundle with rewritten image paths:

- `output/markdown/` — markdown tree preserving the original folder layout
- `output/markdown.tar.gz` — tarball of the markdown tree and copied image assets
