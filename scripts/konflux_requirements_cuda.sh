#!/bin/bash

# Generate hermetic requirements for CUDA Konflux build.
# Uses a copy of pyproject.toml with pytorch-cpu index removed so torch/torchvision can resolve
# from RHOAI (indices below) before PyPI.
#
# Policy — RHOAI torch is canonical for hermetic CUDA images:
#   The installed wheel is from RHOAI pulp (cuda12.9-ubi9), not PyPI CUDA torch. Its METADATA
#   Requires-Dist is the dependency contract (inspect any wheel: scripts/list_wheel_requires_dist.py).
#   Runtime deps must be satisfied in the image; where RHOAI publishes wheels (cuda12.9-ubi9 or
#   cpu-ubi9), use those—not PyPI's separate CUDA torch stack. PyPI CUDA torch adds nvidia-* cu12
#   wheels; RHOAI torch does *not* declare those in METADATA, so do not treat them as required
#   companions to RHOAI torch. triton is declared (e.g. triton==3.5.0) and is installed from
#   RHOAI cpu-ubi9 pulp URLs in the arch-specific requirement files.
#
# Other packages available from RHOAI (cuda12.9-ubi9): see the full list at
#   https://console.redhat.com/api/pypi/public-rhai/rhoai/3.3/cuda12.9-ubi9/simple/
# The resolver already uses RHOAI as first index; packages it picks from RHOAI go to
# requirements.hashes.wheel.cuda.txt. To prefer RHOAI for more packages, add version
# overrides that exist on RHOAI (e.g. in requirements.overrides.cuda.txt) so uv
# resolves them from RHOAI instead of PyPI.

set -ex

RAW_REQ_FILE="requirements.no_hashes.cuda.txt"
SOURCE_FILE="requirements.source.cuda.txt"
WHEEL_FILE="requirements.wheel.cuda.txt"
WHEEL_FILE_PYPI="requirements.wheel.pypi.cuda.txt"
SOURCE_HASH_FILE="requirements.hashes.source.cuda.txt"
WHEEL_HASH_FILE="requirements.hashes.wheel.cuda.txt"
WHEEL_HASH_FILE_PYPI="requirements.hashes.wheel.pypi.cuda.txt"
BUILD_FILE="requirements-build.cuda.txt"
RHOAI_INDEX_URL="https://console.redhat.com/api/pypi/public-rhai/rhoai/3.3/cuda12.9-ubi9/simple/"
# CPU RHOAI index (same version as CUDA): faiss-cpu resolves from here so prefetch can fetch wheels.
RHOAI_INDEX_URL_CPU="${RHOAI_INDEX_URL/cuda12.9-ubi9/cpu-ubi9}"

# cmake: PyPI cmake package (not the rpm); must be prefetched as a wheel or pip builds CMake from sdist during isolated builds (docling-parse build chain).
EXTRA_WHEELS="uv-build,uv,pip,maturin,cmake"
# PyPI wheel list: binary-only packages for the second uv compile. torch/torchvision/triton are
# stripped before that compile and installed from RHOAI pulp in the arch files (see policy above).
# hf-xet omitted: prefetch-dependencies cannot fetch from PyPI (uses RHOAI only), and sdists need Rust 1.85+.
# psycopg2-binary: wheel avoids needing pg_config / libpq-devel.
# faiss-cpu: resolved from RHOAI (CPU index) so prefetch gets the wheel; keep in wheel list.
# llama-index-vector-stores-faiss: wheel-only so prefetch does not build it (and thus faiss-cpu) from source.
# triton: listed for Tekton prefetch package names. Like torch/torchvision, do not pass triton through the
# second `uv pip compile` (PyPI-only)—install RHOAI cpu-ubi9 wheels from arch files (torch declares triton==3.5.0).
PYPI_WHEELS="opencv-python,omegaconf,rapidocr,sqlite-vec,griffe,griffecli,griffelib,pyclipper,tree-sitter-typescript,torch,torchvision,triton,psycopg2-binary,faiss-cpu,llama-index-vector-stores-faiss"
# Split loop: lines matching nvidia-* from pypi.org go to this file if present (not used by RHOAI torch).

# Copy pyproject and remove pytorch-cpu so torch/torchvision come from default PyPI (CUDA).
# uv pip compile only accepts pyproject.toml, so swap temporarily.
# Restore pyproject.toml and uv.lock on exit (success or failure) so we never leave the repo with the CUDA variant.
# uv pip compile can update uv.lock when run with the swapped pyproject.toml.
restore_pyproject() {
	if [ -f pyproject.toml.cpu-only ]; then
		mv -f pyproject.toml pyproject.cuda.toml 2>/dev/null || true
		mv -f pyproject.toml.cpu-only pyproject.toml
		[ -f uv.lock.cpu-only ] && mv -f uv.lock.cpu-only uv.lock
	fi
	rm -f pyproject.cuda.toml pyproject.cpu.bak.toml uv.lock.cpu-only
}
trap restore_pyproject EXIT
cp pyproject.toml pyproject.cpu.bak.toml
cp pyproject.toml pyproject.cuda.toml
[ -f uv.lock ] && cp uv.lock uv.lock.cpu-only
uv run python ./scripts/remove_pytorch_cpu_pyproject.py pyproject.cuda.toml
mv pyproject.toml pyproject.toml.cpu-only
mv pyproject.cuda.toml pyproject.toml

# Generate requirements from CUDA pyproject (torch from PyPI = CUDA on Linux).
# Use CPU RHOAI as extra index so faiss-cpu (and similar) resolve from RHOAI and prefetch can fetch wheels.
uv pip compile pyproject.toml -o "$RAW_REQ_FILE" \
	--python-version 3.12 \
	--refresh \
	--index "$RHOAI_INDEX_URL" \
	--extra-index-url "$RHOAI_INDEX_URL_CPU" \
	--default-index https://pypi.org/simple/ \
	--index-strategy unsafe-best-match \
	--emit-index-annotation \
	--no-sources \
	--override requirements.overrides.cuda.txt

# Restore original pyproject.toml and uv.lock (trap will also run on exit and clean up)
mv pyproject.toml pyproject.cuda.toml
mv pyproject.toml.cpu-only pyproject.toml
[ -f uv.lock.cpu-only ] && mv -f uv.lock.cpu-only uv.lock
rm -f pyproject.cpu.bak.toml uv.lock.cpu-only

# Initialize output files
echo "# Packages from pypi.org (CUDA build)" > "$SOURCE_FILE"
echo "# This file was autogenerated by konflux_requirements_cuda.sh" >> "$SOURCE_FILE"
echo "# Packages from console.redhat.com" > "$WHEEL_FILE"
echo "# This file was autogenerated by konflux_requirements_cuda.sh" >> "$WHEEL_FILE"
echo "--index-url $RHOAI_INDEX_URL" >> "$WHEEL_FILE"
echo "# Packages from pypi.org to be fetched as wheels" > "$WHEEL_FILE_PYPI"
echo "# This file was autogenerated by konflux_requirements_cuda.sh" >> "$WHEEL_FILE_PYPI"

current_package=""
while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[a-zA-Z0-9] ]]; then
        current_package="$line"
    elif [[ "$line" =~ ^[[:space:]]*#[[:space:]]*from[[:space:]]+(.*) ]]; then
        index_url="${BASH_REMATCH[1]}"
        if [[ -n "$current_package" ]]; then
            if [[ "$index_url" == "https://pypi.org/simple/" ]]; then
                package_name=$(echo "$current_package" | sed 's/[=<>!].*//')
                if echo ",${PYPI_WHEELS}," | grep -qF ",${package_name}," || [[ "$package_name" == nvidia-* ]]; then
                    echo "$current_package" >> "$WHEEL_FILE_PYPI"
                else
                    echo "$current_package" >> "$SOURCE_FILE"
                fi
            elif [[ "$index_url" == "$RHOAI_INDEX_URL" ]]; then
                echo "$current_package" >> "$WHEEL_FILE"
            elif [[ "$index_url" == "$RHOAI_INDEX_URL_CPU" ]]; then
                # CPU RHOAI packages: hermeto uses only CUDA index for wheel file. If PyPI has a wheel (e.g. faiss-cpu), use PyPI wheel list so we don't build from source.
                package_name=$(echo "$current_package" | sed 's/[=<>!].*//')
                if echo ",${PYPI_WHEELS}," | grep -qF ",${package_name},"; then
                    echo "$current_package" >> "$WHEEL_FILE_PYPI"
                else
                    echo "$current_package" >> "$SOURCE_FILE"
                fi
            fi
            current_package=""
        fi
    fi
done < "$RAW_REQ_FILE"

# torch/torchvision are listed here when resolved from RHOAI cpu-ubi9 (still matched via PYPI_WHEELS).
# The next step runs `uv pip compile` with only the default index (PyPI). If torch==… is present, uv
# resolves PyPI's CUDA torch and pulls in nvidia-* cu12 wheels—even though hermetic install uses RHOAI
# pulp wheels from requirements.hashes.wheel.pypi.cuda.{x86_64,aarch64}.txt. Strip torch/torchvision
# so the second compile cannot re-expand PyPI CUDA torch deps (spurious nvidia-*).
grep -vE '^(torch|torchvision|triton)(==|[[:space:]]+@)' "$WHEEL_FILE_PYPI" > "${WHEEL_FILE_PYPI}.tmp" && mv "${WHEEL_FILE_PYPI}.tmp" "$WHEEL_FILE_PYPI"

# Update CUDA pipeline configs with binary package list (RHOAI + extra + PyPI wheels including torch/nvidia-*)
wheel_packages=$(grep -v "^[#-]" "$WHEEL_FILE" | sed 's/==.*//' | tr '\n' ',' | sed 's/,$//')
pypi_wheel_packages=$(grep -v "^[#-]" "$WHEEL_FILE_PYPI" | sed 's/==.*//' | tr '\n' ',' | sed 's/,$//')
wheel_packages="$wheel_packages,$EXTRA_WHEELS,$PYPI_WHEELS,$pypi_wheel_packages"
# Merge can repeat names (e.g. triton from WHEEL_FILE and PYPI_WHEELS; PyPI wheels also in PYPI_WHEELS).
wheel_packages=$(printf '%s' "$wheel_packages" | tr ',' '\n' | awk 'NF && !seen[$0]++' | paste -sd, -)
# Update CUDA pipeline configs (c0ec3 only; do not modify rag-tool-*-cuda.yaml).
for f in .tekton/lightspeed-core-rag-content-c0ec3-pull-request.yaml .tekton/lightspeed-core-rag-content-c0ec3-push.yaml; do
    if [[ -f "$f" ]]; then
        sed -i 's/"packages": "[^"]*"/"packages": "'"$wheel_packages"'"/' "$f"
    fi
done

echo "Packages from pypi.org written to: $SOURCE_FILE ($(wc -l < "$SOURCE_FILE") packages)"
echo "Packages from console.redhat.com written to: $WHEEL_FILE ($(wc -l < "$WHEEL_FILE") packages)"

# Generate hashed requirement files. Wheel file has only CUDA RHOAI packages (no --extra-index-url; hermeto does not support it).
uv pip compile "$WHEEL_FILE" --refresh --generate-hashes --index-url "$RHOAI_INDEX_URL" --python-version 3.12 --emit-index-url --no-deps --no-annotate --universal > "$WHEEL_HASH_FILE"
# --only-binary :all: so hashes are for wheels only; include deps for transitive wheels (torch/torchvision
# are stripped from WHEEL_FILE_PYPI above so PyPI CUDA torch does not pull nvidia-*; triton etc. remain).
# Pin omegaconf to 2.3.0+ so pip 24.1+ accepts metadata (2.0.6 uses deprecated PyYAML >=5.1.*).
sed -i 's/^omegaconf==[0-9.]*/omegaconf==2.3.0/' "$WHEEL_FILE_PYPI"
uv pip compile "$WHEEL_FILE_PYPI" --refresh --generate-hashes --only-binary ':all:' --python-version 3.12 --emit-index-url --no-annotate > "$WHEEL_HASH_FILE_PYPI"
# faiss-cpu: use direct wheel URLs so prefetch fetches only wheels (no sdist) and the build never tries to build from source.
# File has both arches; Containerfile filters to the single faiss-cpu line for TARGETARCH so pip installs only one wheel.
faiss_version=$(awk '/^faiss-cpu==/ { match($0, /[0-9]+\.[0-9]+\.[0-9]+/); print substr($0, RSTART, RLENGTH); exit } /^faiss-cpu @ / { if (match($0, /faiss_cpu-[0-9]+\.[0-9]+\.[0-9]+/)) { print substr($0, RSTART+9, RLENGTH-9); exit } }' "$WHEEL_HASH_FILE_PYPI")
if [ -n "$faiss_version" ]; then
  FAISS_CPU_SPEC=$(python3 -c "
import urllib.request, json, sys
ver = sys.argv[1]
url = f'https://pypi.org/pypi/faiss-cpu/{ver}/json'
with urllib.request.urlopen(url) as r:
    d = json.load(r)
wheels = []
for u in d.get('urls', []):
    if (u.get('packagetype') == 'bdist_wheel' and 'cp312' in u.get('filename', '') and 'manylinux' in u.get('filename', '')):
        wheels.append((u['filename'], u['url'], u['digests'].get('sha256')))
wheels.sort(key=lambda x: x[0])
if len(wheels) < 2:
    sys.exit(1)
for fn, u, h in wheels:
    print(u)
    print(h)
" "$faiss_version") || { echo "Could not get faiss-cpu wheel URLs (x86_64 and aarch64) from PyPI for version $faiss_version"; exit 1; }
  FAISS_URL_1=$(echo "$FAISS_CPU_SPEC" | sed -n '1p')
  FAISS_HASH_1=$(echo "$FAISS_CPU_SPEC" | sed -n '2p')
  FAISS_URL_2=$(echo "$FAISS_CPU_SPEC" | sed -n '3p')
  FAISS_HASH_2=$(echo "$FAISS_CPU_SPEC" | sed -n '4p')
  awk -v url1="$FAISS_URL_1" -v hash1="$FAISS_HASH_1" -v url2="$FAISS_URL_2" -v hash2="$FAISS_HASH_2" '
/^faiss-cpu==/ || /^faiss-cpu @ / {
  print "faiss-cpu @ " url1 " \\"
  print "    --hash=sha256:" hash1
  print "faiss-cpu @ " url2 " \\"
  print "    --hash=sha256:" hash2
  skip=1
  next
}
skip && /^[a-zA-Z0-9][a-zA-Z0-9_.-]*(==| @ )/ && $0 !~ /^faiss-cpu/ { skip=0 }
!skip { print }
' "$WHEEL_HASH_FILE_PYPI" > "$WHEEL_HASH_FILE_PYPI.tmp" && mv "$WHEEL_HASH_FILE_PYPI.tmp" "$WHEEL_HASH_FILE_PYPI"
  # Arch files: only the one faiss-cpu block per arch (base is generated at end, after omegaconf/deprecated).
  # Wheels are sorted by filename: aarch64 then x86_64, so URL_1/HASH_1 = aarch64, URL_2/HASH_2 = x86_64.
  printf 'faiss-cpu @ %s \\\n    --hash=sha256:%s\n' "$FAISS_URL_1" "$FAISS_HASH_1" > "${WHEEL_HASH_FILE_PYPI%.txt}.aarch64.txt"
  printf 'faiss-cpu @ %s \\\n    --hash=sha256:%s\n' "$FAISS_URL_2" "$FAISS_HASH_2" > "${WHEEL_HASH_FILE_PYPI%.txt}.x86_64.txt"
  # aarch64: PyPI only has CPU torch/torchvision. Use RHOAI for both (already prefetched).
  # RHOAI index: https://console.redhat.com/api/pypi/public-rhai/rhoai/3.3/cuda12.9-ubi9/simple/
  RHOAI_PULP="https://packages.redhat.com/api/pulp-content/public-rhai/rhoai/3.3/cuda12.9-ubi9"
  AARCH64_TORCH_URL="${RHOAI_PULP}/torch-2.9.0-13-cp312-cp312-linux_aarch64.whl"
  AARCH64_TORCH_HASH="5059b9516b74ad4a7a5d37a9243d749d957ee002378960ce5c67f7bb23fc8154"
  AARCH64_TORCHVISION_URL="${RHOAI_PULP}/torchvision-0.24.0-9-cp312-cp312-linux_aarch64.whl"
  AARCH64_TORCHVISION_HASH="569d6ab37fb575f514d04c04706a65fc599f24c7b6264b44e54b9b9c017e353a"
  RHOAI_PULP_CPU="https://packages.redhat.com/api/pulp-content/public-rhai/rhoai/3.3/cpu-ubi9"
  AARCH64_TRITON_URL="${RHOAI_PULP_CPU}/triton-3.5.0-3-cp312-cp312-linux_aarch64.whl"
  AARCH64_TRITON_HASH="a46eaadd18e726ff38f9cfb53c4e641dfe937741394cdf45e2981858200fae1d"
  {
    echo ""
    echo "# aarch64 CUDA: torch and torchvision from RHOAI (PyPI only has CPU on aarch64)"
    echo "torch @ ${AARCH64_TORCH_URL} \\"
    echo "    --hash=sha256:${AARCH64_TORCH_HASH}"
    echo "torchvision @ ${AARCH64_TORCHVISION_URL} \\"
    echo "    --hash=sha256:${AARCH64_TORCHVISION_HASH}"
    echo "# triton from RHOAI cpu-ubi9 (declared by RHOAI torch METADATA)"
    echo "triton @ ${AARCH64_TRITON_URL} \\"
    echo "    --hash=sha256:${AARCH64_TRITON_HASH}"
  } >> "${WHEEL_HASH_FILE_PYPI%.txt}.aarch64.txt"
fi
# Replace omegaconf 2.0.6 with 2.3.0 so pip 24.1+ accepts metadata (2.0.6 uses deprecated PyYAML >=5.1.*).
OMEGACONF_SPEC=$(python3 -c "
import urllib.request, json, sys
url = 'https://pypi.org/pypi/omegaconf/2.3.0/json'
with urllib.request.urlopen(url) as r:
    d = json.load(r)
for u in d.get('urls', []):
    if u.get('packagetype') == 'bdist_wheel' and 'py3' in u.get('filename', ''):
        print(u['url'])
        print(u['digests']['sha256'])
        break
" 2>/dev/null) || true
if [ -n "$OMEGACONF_SPEC" ]; then
  OMEGACONF_URL=$(echo "$OMEGACONF_SPEC" | head -1)
  OMEGACONF_HASH=$(echo "$OMEGACONF_SPEC" | tail -1)
  awk -v url="$OMEGACONF_URL" -v hash="$OMEGACONF_HASH" '
/^omegaconf==/ {
  print "omegaconf==2.3.0 \\"
  print "    --hash=sha256:" hash
  skip=1
  next
}
skip && /^[a-zA-Z0-9][a-zA-Z0-9_.-]*==/ { skip=0 }
skip && /^[a-zA-Z0-9][a-zA-Z0-9_.-]* @ / { skip=0 }
!skip { print }
' "$WHEEL_HASH_FILE_PYPI" > "$WHEEL_HASH_FILE_PYPI.tmp" && mv "$WHEEL_HASH_FILE_PYPI.tmp" "$WHEEL_HASH_FILE_PYPI"
fi
# Replace deprecated with 1.2.18 wheel URL so prefetch fetches the wheel (not sdist; sdist causes checksum mismatch).
DEPRECATED_WHEEL_URL="https://files.pythonhosted.org/packages/6e/c6/ac0b6c1e2d138f1002bcf799d330bd6d85084fece321e662a14223794041/Deprecated-1.2.18-py2.py3-none-any.whl"
DEPRECATED_HASH=bd5011788200372a32418f888e326a09ff80d0214bd961147cfed01b5c018eec
awk -v url="$DEPRECATED_WHEEL_URL" -v hash="$DEPRECATED_HASH" '
/^deprecated==/ {
  print "deprecated @ " url " \\"
  print "    --hash=sha256:" hash
  skip=1
  next
}
skip && /^[a-zA-Z0-9][a-zA-Z0-9_.-]*==/ { skip=0 }
skip && /^[a-zA-Z0-9][a-zA-Z0-9_.-]* @ / { skip=0 }
!skip { print }
' "$WHEEL_HASH_FILE_PYPI" > "$WHEEL_HASH_FILE_PYPI.tmp" && mv "$WHEEL_HASH_FILE_PYPI.tmp" "$WHEEL_HASH_FILE_PYPI"
# wrapt: first pass pins 1.17.x in requirements.hashes.wheel.cuda.txt (RHOAI, satisfies deprecated<2).
# The second PyPI compile can still add wrapt 2.x as a transitive dep; dedup below would drop RHOAI and keep
# PyPI (wrong). Strip wrapt from the PyPI wheel file when RHOAI already provides it.
if grep -q '^wrapt==' "$WHEEL_HASH_FILE"; then
	awk '/^wrapt==/{skip=1; next} skip && /^[a-zA-Z0-9][a-zA-Z0-9_.-]*(==| @ )/{skip=0} skip && /^[[:space:]]*--hash=/{next} !skip{print}' "$WHEEL_HASH_FILE_PYPI" > "$WHEEL_HASH_FILE_PYPI.tmp" && mv "$WHEEL_HASH_FILE_PYPI.tmp" "$WHEEL_HASH_FILE_PYPI"
fi
# Deduplicate: prefetch may fetch from PyPI for packages in both files; pip then sees one wheel (PyPI hash). Remove from RHOAI wheel file any package also in PyPI wheel file so hashes match.
awk 'FNR==NR { if (/^[a-zA-Z0-9].*(==| @ )/) { match($0, /^[a-zA-Z0-9][a-zA-Z0-9_.-]*/); p[substr($0,RSTART,RLENGTH)]=1 }; next }
     /^#/ { print; next }
     /^--index-url/ { print; next }
     /^[a-zA-Z0-9].*(==| @ )/ { match($0, /^[a-zA-Z0-9][a-zA-Z0-9_.-]*/); name=substr($0,RSTART,RLENGTH); skip=(name in p); if (!skip) print; next }
     { if (!skip) print }' "$WHEEL_HASH_FILE_PYPI" "$WHEEL_HASH_FILE" > "$WHEEL_HASH_FILE.tmp" && mv "$WHEEL_HASH_FILE.tmp" "$WHEEL_HASH_FILE"
uv pip compile "$SOURCE_FILE" --refresh --generate-hashes --python-version 3.12 --emit-index-url --no-deps --no-annotate > "$SOURCE_HASH_FILE"
# Prefetch cannot fetch from PyPI; omit hf-xet so hermetic build succeeds (huggingface_hub works without it).
awk '/^hf-xet==/{skip=1; next} skip && /^[a-zA-Z0-9][a-zA-Z0-9_.-]*==/{skip=0} !skip{print}' "$SOURCE_HASH_FILE" > "$SOURCE_HASH_FILE.tmp" && mv "$SOURCE_HASH_FILE.tmp" "$SOURCE_HASH_FILE"
# Only install psycopg2-binary from wheel list (avoids pg_config); strip from source in case it appears there.
awk '/^psycopg2-binary==/{skip=1; next} skip && /^[a-zA-Z0-9][a-zA-Z0-9_.-]*==/{skip=0} !skip{print}' "$SOURCE_HASH_FILE" > "$SOURCE_HASH_FILE.tmp" && mv "$SOURCE_HASH_FILE.tmp" "$SOURCE_HASH_FILE"
# faiss-cpu does not build from sdist (SWIG/headers); must come from wheel (PyPI). Strip from source hashes if present.
awk '/^faiss-cpu==/{skip=1; next} skip && /^[a-zA-Z0-9][a-zA-Z0-9_.-]*==/{skip=0} !skip{print}' "$SOURCE_HASH_FILE" > "$SOURCE_HASH_FILE.tmp" && mv "$SOURCE_HASH_FILE.tmp" "$SOURCE_HASH_FILE"
# llama-index-vector-stores-faiss depends on faiss-cpu; keep it wheel-only so prefetch never builds faiss-cpu.
awk '/^llama-index-vector-stores-faiss==/{skip=1; next} skip && /^[a-zA-Z0-9][a-zA-Z0-9_.-]*==/{skip=0} !skip{print}' "$SOURCE_HASH_FILE" > "$SOURCE_HASH_FILE.tmp" && mv "$SOURCE_HASH_FILE.tmp" "$SOURCE_HASH_FILE"
# PyPI has no sdists for torch/torchvision/triton/nvidia-*; strip from source hashes if they landed here (e.g. from CPU RHOAI).
awk '/^(torch|torchvision|triton|nvidia-[a-zA-Z0-9_-]+)==/{skip=1; next} skip && /^[a-zA-Z0-9][a-zA-Z0-9_.-]*==/{skip=0} !skip{print}' "$SOURCE_HASH_FILE" > "$SOURCE_HASH_FILE.tmp" && mv "$SOURCE_HASH_FILE.tmp" "$SOURCE_HASH_FILE"
# Avoid duplicate version conflict: remove from source any package already in PyPI wheel file (e.g. aiosqlite 0.22.0 in source vs 0.22.1 in wheel).
awk 'FNR==NR { if (/^[a-zA-Z0-9].*(==| @ )/) { match($0, /^[a-zA-Z0-9][a-zA-Z0-9_.-]*/); p[substr($0,RSTART,RLENGTH)]=1 }; next }
     /^#/ { print; next }
     /^--index-url/ { print; next }
     /^[a-zA-Z0-9].*(==| @ )/ { match($0, /^[a-zA-Z0-9][a-zA-Z0-9_.-]*/); name=substr($0,RSTART,RLENGTH); skip=(name in p); if (!skip) print; next }
     { if (!skip) print }' "$WHEEL_HASH_FILE_PYPI" "$SOURCE_HASH_FILE" > "$SOURCE_HASH_FILE.tmp" && mv "$SOURCE_HASH_FILE.tmp" "$SOURCE_HASH_FILE"
# PyPI wheels: emit base (all packages minus faiss-cpu, torch, torchvision) and remove full file.
# torch/torchvision are arch-specific: x86_64 from PyPI (in .x86_64.txt), aarch64 from RHOAI (in .aarch64.txt).
# So prefetch does not fetch PyPI torch/torchvision for both arches (which would pull the unused aarch64 CPU wheel).
awk '
/^faiss-cpu @ / { getline; next }
/^torch==/ { skip=1; next }
/^torchvision==/ { skip=1; next }
/^triton==/ { skip=1; next }
skip && /^[[:space:]]/ { next }
skip && /^[a-zA-Z0-9]/ { skip=0 }
skip { next }
{ print }
' "$WHEEL_HASH_FILE_PYPI" > "${WHEEL_HASH_FILE_PYPI%.txt}.base.txt"
# x86_64: torch, torchvision, triton from RHOAI (triton: cpu-ubi9, matches torch Requires-Dist triton==3.5.0).
RHOAI_PULP="https://packages.redhat.com/api/pulp-content/public-rhai/rhoai/3.3/cuda12.9-ubi9"
RHOAI_PULP_CPU="https://packages.redhat.com/api/pulp-content/public-rhai/rhoai/3.3/cpu-ubi9"
TRITON_350_X86_URL="${RHOAI_PULP_CPU}/triton-3.5.0-3-cp312-cp312-linux_x86_64.whl"
TRITON_350_X86_HASH="a916a1758674bbc35545f3aed9c1e83ed581b59a277cfffca1926c6f5f567a96"
if [ -f "${WHEEL_HASH_FILE_PYPI%.txt}.x86_64.txt" ]; then
  {
    echo ""
    echo "# x86_64: torch and torchvision from RHOAI cuda12.9-ubi9 (same version as aarch64)"
    echo "torch @ ${RHOAI_PULP}/torch-2.9.0-13-cp312-cp312-linux_x86_64.whl \\"
    echo "    --hash=sha256:6a331fdd10983a88751dcc0e5175a2e4c432225774bbb7931c1d249b55a40816"
    echo "torchvision @ ${RHOAI_PULP}/torchvision-0.24.0-9-cp312-cp312-linux_x86_64.whl \\"
    echo "    --hash=sha256:c1b4ffe7435b2a6e4c849b1be3b1f50d8f1fcb5a9c1bbe6f38e59af57eb27abb"
    echo "# triton from RHOAI cpu-ubi9 (declared by RHOAI torch METADATA)"
    echo "triton @ ${TRITON_350_X86_URL} \\"
    echo "    --hash=sha256:${TRITON_350_X86_HASH}"
  } >> "${WHEEL_HASH_FILE_PYPI%.txt}.x86_64.txt"
fi
rm -f "$WHEEL_HASH_FILE_PYPI"
# faiss-cpu from CPU RHOAI is in source list; prefetch will get it from PyPI when processing that file (or build from sdist).
# pybuild-deps needs source (sdist); exclude wheel-only packages (torch, torchvision, triton, nvidia-*, faiss-cpu) that may have landed in source list.
grep -v -E '^(torch|torchvision|faiss-cpu|triton|nvidia-[a-zA-Z0-9_-]+)==' "$SOURCE_FILE" > "$SOURCE_FILE.build"
uv run pybuild-deps compile --output-file="$BUILD_FILE" "$SOURCE_FILE.build"
rm -f "$SOURCE_FILE.build"

sed -i 's/maturin==[0-9.]*/maturin==1.10.2/' "$BUILD_FILE"

# Remove intermediate files
rm -f "$RAW_REQ_FILE" "$WHEEL_FILE" "$WHEEL_FILE_PYPI" "$SOURCE_FILE" pyproject.cuda.toml

echo "Done!"
echo "Packages from pypi.org written to: $SOURCE_HASH_FILE ($(grep -Eo '==[0-9.]+' "$SOURCE_HASH_FILE" | wc -l) packages)"
echo "Packages from console.redhat.com written to: $WHEEL_HASH_FILE ($(grep -Eo '==[0-9.]+' "$WHEEL_HASH_FILE" | wc -l) packages)"
echo "Packages from pypi.org (wheels) written to: ${WHEEL_HASH_FILE_PYPI%.txt}.base.txt + .x86_64.txt + .aarch64.txt ($(grep -Eo '==[0-9.]+' "${WHEEL_HASH_FILE_PYPI%.txt}.base.txt" | wc -l) in base, faiss-cpu per arch)"
echo "Build dependencies written to: $BUILD_FILE ($(grep -Eo '==[0-9.]+' "$BUILD_FILE" | wc -l) packages)"
echo "Remember to commit the .cuda.txt requirement files, pipeline configurations and push the changes"
