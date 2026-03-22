# Agent notes: Konflux, Hermeto, and hermetic Python lockfiles

This file captures lessons from debugging **prefetch-dependencies / Hermeto** failures (checksum mismatch, “No wheels found”, `pybuild-deps` errors) and aligning **CPU** and **CUDA** requirement generators. Use it when changing `pyproject.toml`, RHOAI indices, or `.tekton` prefetch inputs.

## Hermeto behavior that breaks naive lockfiles

- **Konflux invocation** (shape to mirror locally):  
  `hermeto --log-level debug --mode strict fetch-deps '<json>' --sbom-output-type spdx --source <repo> --output <dir>`  
  The pip slice of `<json>` matches `.tekton` `prefetch-input` (see `scripts/hermeto/*.json` and `scripts/run_hermeto_fetch_deps.sh`).

- **PyPI intersection for wheels**  
  For many binary packages, Hermeto logs lines like:  
  `using intersection of requirements-file and PyPI-reported checksums`  
  It then **drops** any wheel whose digest is not in that intersection.

- **Implication for RHOAI**  
  If a line uses **`package==version`** with **`--index-url`** pointing at RHOAI but the **actual wheel file** is a RHOAI rebuild (e.g. `torch-2.9.0-7-cp312-cp312-linux_x86_64.whl`), PyPI usually **does not** expose the same filename/digest. **Every** candidate can be filtered → `PackageRejected: No wheels found`.

- **What fixes it**  
  - Prefer **`name @ https://…/exact-file.whl`** plus a **single `--hash=sha256:…`** for bytes you control (pulp or `files.pythonhosted.org`), so Hermeto fetches by URL and verifies the hash **without** requiring a PyPI match for that RHOAI rebuild name.  
  - For **CPU multi-arch**, the prefetch lists **both** arch-specific requirement fragments; **`Containerfile`** installs **one** fragment according to `TARGETARCH` (see below).

- **Local Hermeto**  
  Run `./scripts/run_hermeto_fetch_deps.sh pip-cpu` (or `pip-cuda`). **`full-cpu`** may fail without **RHSM** client cert paths—Konflux injects `options.ssl` on the **rpm** input; laptops typically do not have `/etc/pki/entitlement/…`.

## CPU pipeline (`scripts/konflux_requirements.sh`)

- **Regenerate; do not hand-edit** hashed requirements. Use `make konflux-requirements` (or the script).

- **`--extra-index-url` in lockfiles**  
  Hermeto does not support that line in committed files. The script passes PyPI as an extra index **during** `uv pip compile`, then **`sed`** removes `--extra-index-url` from the generated file.

- **Torch / triton (RHOAI) vs Hermeto**  
  `torch==` / `triton==` under the RHOAI simple index **fail** Hermeto’s PyPI intersection. The generator **strips** those stanzas from `requirements.hashes.wheel.txt` and writes:  
  - `requirements.hashes.wheel.cpu.x86_64.txt` — pulp URLs + hashes for **torch** and **triton**; **torchvision** from **PyPI manylinux** URLs (so PyPI intersection succeeds).  
  - `requirements.hashes.wheel.cpu.aarch64.txt` — same pattern for aarch64.  
  **`Containerfile`** selects one of these via `TARGETARCH` (`amd64` → `x86_64`, `arm64` → `aarch64`).

- **`pylatexenc` on the PyPI wheel file**  
  Same intersection issue: PyPI digest ≠ RHOAI rebuild `*-8-py3-none-any.whl`. After the PyPI-wheel compile, the script rewrites **`pylatexenc==…`** to a **pulp direct URL** (currently the **cuda12.9-ubi9** artifact; the **3.2/cpu-ubi9** pulp path returned 404 for that filename when checked).

- **`pybuild-deps`**  
  It cannot use sdists for **`nvidia-*`**, **`torch` / `torchvision` / `triton`**, **`faiss-cpu`** in this layout. The script feeds a filtered temp file to `pybuild-deps` (see script comments).

- **Tekton / JSON sync**  
  When `prefetch-input` **`requirements_files`** or **`binary.packages`** change, update **`.tekton/rag-tool-*.yaml`**, **`.tekton/lightspeed-core-rag-content-cpu-f176b-*.yaml`**, and **`scripts/hermeto/prefetch-*.json`** together. The konflux script only rewrites the **`"packages"`** string in some Tekton files via `sed`; it does **not** auto-insert new requirement filenames everywhere.

## CUDA pipeline (`scripts/konflux_requirements_cuda.sh`)

- **Regenerate** with `make konflux-requirements-cuda`.

- **Policy**  
  RHOAI **CUDA** `torch` is canonical; do not assume PyPI CUDA `torch`’s `nvidia-*` graph applies. See `README.md` (CUDA / RHOAI / `list_wheel_requires_dist.py`).

- **CUDA-specific mechanics**  
  - Strip **`torch` / `torchvision` / `triton`** from the **second** PyPI-only compile input so PyPI CUDA torch does not pull **`nvidia-*`** into that file.  
  - **Sdist-only on PyPI**: pins are moved back to the RHOAI wheel file so `--only-binary :all:` can still run.  
  - **`antlr4-python3-runtime`**: PyPI has no usable wheel for omegaconf’s constraints; inject **pulp URL** + fixed stanza/hash.  
  - **`pylatexenc`**: pulp URL + hash on the appropriate file (same Hermeto intersection issue as CPU).  
  - **`pybuild-deps`**: filtered input excludes wheel-only / problematic packages (see script).  
  - **Wheel layout**: `requirements.hashes.wheel.pypi.cuda.base.txt` plus **`.x86_64.txt` / `.aarch64.txt`** — **not** a single `requirements.hashes.wheel.pypi.cuda.txt` (some older Tekton snippets may still be wrong; **c0ec3** YAMLs are the reference).

- **rag-tool-cuda Tekton**  
  If prefetch lists the wrong CUDA wheel filenames, fix them to match **`Containerfile-cuda`** and **`lightspeed-core-rag-content-c0ec3-*`**.

## Operational checklist after dependency changes

1. Run **`make konflux-requirements`** and/or **`make konflux-requirements-cuda`**.  
2. Commit generated **`requirements.hashes.*`**, **`requirements-build*.txt`**, new **`requirements.hashes.wheel.cpu.*.txt`** when CPU script emits them, **`Containerfile`** if install paths change, and **`.tekton` / `scripts/hermeto`** if prefetch inputs change.  
3. Optionally run **`./scripts/run_hermeto_fetch_deps.sh pip-cpu`** or **`pip-cuda`** to validate Hermeto against the pip slice.  
4. If RHOAI **rebuilds** wheels (new `-*-` segment in filenames), update **pulp URLs / hashes** in the generator constants (and re-run Hermeto).

## References

- [Hermeto](https://github.com/hermetoproject/hermeto) — prefetch CLI and container image.  
- In-repo: `scripts/konflux_requirements.sh`, `scripts/konflux_requirements_cuda.sh`, `scripts/run_hermeto_fetch_deps.sh`, `scripts/hermeto/*.json`, `README.md` (Konflux / CUDA sections).
