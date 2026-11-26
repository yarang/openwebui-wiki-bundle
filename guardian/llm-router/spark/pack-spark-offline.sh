#!/usr/bin/env bash
# pack-spark-offline.sh — build the self-contained offline (air-gapped)
# install bundle for DGX Spark. Runs on a CONNECTED arm64 Linux host with
# docker — normally the DGX itself while it still has internet. The bundle is
# consumed by install-spark-offline.sh on the air-gapped DGX; that script
# makes zero network calls, so everything it needs must be in here.
#
#   ./pack-spark-offline.sh --out /mnt/usb/spark-bundle
#   ./pack-spark-offline.sh --out DIR --profiles gpt-oss-120b,qwen3-coder
#   ./pack-spark-offline.sh --out DIR --k3s-version v1.36.6+k3s1
#   ./pack-spark-offline.sh --out DIR --hf-cache /path/to/huggingface
#   ./pack-spark-offline.sh --out DIR --no-models --no-k3s --no-images
#   ./pack-spark-offline.sh --out DIR --include-all-files  # keep original/,
#   ./pack-spark-offline.sh --out DIR --resume    # continue after a failure
#   ./pack-spark-offline.sh --out DIR --dry-run   # print every command only
#
# Each component is staged in a <name>.partial directory and renamed into
# place only when complete; the .done-<component> marker is written last, so
# --resume can skip finished components. Models resume per profile: each model
# is staged in hf.partial/hub/models--X.partial and moved into place with a
# .done-model-<profile> marker, so one huge model never forces re-downloading
# the others. Rebuilding models never deletes hf/tiktoken. MANIFEST.json and
# SHA256SUMS are regenerated at the end of every real run and are refused
# while any *.partial directory is left. A secret guard then refuses a bundle
# that carries a real SWITCH_TOKEN / VLLM_API_KEY / HF_TOKEN assignment
# (under spark/ or in MANIFEST.json) or a file named env / *.key / token*
# anywhere. HF_TOKEN may be set in the environment for gated repos — it is
# inherited by the download tools (docker gets -e HF_TOKEN, the name only)
# and never written, echoed or passed as a value in an argument vector.

set -euo pipefail

# k3s release to bundle. Must be >= v1.30: k8s/policy uses
# admissionregistration.k8s.io/v1 (ValidatingAdmissionPolicy), GA in 1.30.
K3S_VERSION_DEFAULT="v1.36.6+k3s1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILES_FILE="${PROFILES_FILE:-$SCRIPT_DIR/profiles.json}"
DEVICE_PLUGIN_YAML="$SCRIPT_DIR/k8s/device-plugin/nvidia-device-plugin.yaml"

VLLM_IMAGE="${VLLM_IMAGE:-nvcr.io/nvidia/vllm:26.02-py3}"

OUT=""
PROFILES_SEL="all"
K3S_VERSION="$K3S_VERSION_DEFAULT"
HF_CACHE="${HF_CACHE:-$HOME/.cache/huggingface}"
NO_MODELS=0
NO_K3S=0
NO_IMAGES=0
RESUME=0
DRY_RUN=0
INCLUDE_ALL=0

# Duplicate weight trees that ship inside several repos (the safetensors are
# converted copies of original/; metal/ is the Apple-ARM variant). They are
# excluded from every model source by default; --include-all-files disables
# this list below.
EXCLUDE_GLOBS=("original/*" "metal/*")

# The spark/ payload of the bundle — exactly these files (never tests/,
# __pycache__, env, *.key or any secret).
SPARK_FILES="spark_switch.py spark_common.py spark_backend_docker.py \
spark_backend_kube.py profiles.json env.example README.md \
install-spark-switch.sh install-spark-k8s.sh install-spark-offline.sh"

usage() {
  cat <<'EOF'
Usage: pack-spark-offline.sh --out DIR [--profiles all|p1,p2]
                             [--k3s-version V] [--hf-cache DIR]
                             [--no-models] [--no-k3s] [--no-images]
                             [--include-all-files] [--resume] [--dry-run]
                             [-h|--help]

  --out DIR             bundle directory to create (must be empty unless
                        --resume)
  --profiles            "all" (default) or a comma-separated profile list
  --k3s-version         k3s release tag (default: v1.36.6+k3s1; >= v1.30
                        required)
  --hf-cache            HuggingFace cache to copy models from
                        (default: $HOME/.cache/huggingface)
  --no-models           skip the hf/hub component (also skips tiktoken)
  --no-k3s              skip the k3s component
  --no-images           skip the images component
  --include-all-files   do NOT exclude the duplicate original/ and metal/
                        weight trees (they roughly double each model)
  --resume              allow a non-empty --out and skip components whose
                        .done-<component> marker already exists (and models
                        whose .done-model-<profile> marker exists)
  --dry-run             print every command with a leading "+ "; create
                        nothing

Environment: VLLM_IMAGE (default nvcr.io/nvidia/vllm:26.02-py3),
HF_CACHE. The device plugin image is read from
k8s/device-plugin/nvidia-device-plugin.yaml (single source of truth).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="${2:?--out needs a value}"; shift 2 ;;
    --profiles) PROFILES_SEL="${2:?--profiles needs a value}"; shift 2 ;;
    --k3s-version) K3S_VERSION="${2:?--k3s-version needs a value}"; shift 2 ;;
    --hf-cache) HF_CACHE="${2:?--hf-cache needs a value}"; shift 2 ;;
    --no-models) NO_MODELS=1; shift ;;
    --no-k3s) NO_K3S=1; shift ;;
    --no-images) NO_IMAGES=1; shift ;;
    --include-all-files) INCLUDE_ALL=1; shift ;;
    --resume) RESUME=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$OUT" ]]; then
  echo "--out DIR is required" >&2
  exit 2
fi

note() { echo "[pack-offline] $*"; }

run() {
  echo "+ $*"
  if [[ $DRY_RUN -eq 0 ]]; then
    "$@"
  fi
}

fetch() {  # url dest — every network fetch of this script
  run curl -fL --retry 3 -o "$2" "$1"
}

# The exclusion list as a single comma-joined value for tools and the python
# helpers ("-" = exclude nothing, i.e. --include-all-files).
exclude_csv() {
  if [[ $INCLUDE_ALL -eq 1 ]]; then
    printf '%s' "-"
    return 0
  fi
  local g out=""
  for g in "${EXCLUDE_GLOBS[@]}"; do
    out="${out:+$out,}$g"
  done
  printf '%s' "$out"
}

# ---------------------------------------------------------------- checks ----

if ! [[ "$K3S_VERSION" =~ ^v([0-9]+)\.([0-9]+)(\.[0-9]+)?(\+[0-9A-Za-z._-]+)?$ ]]; then
  echo "k3s version must look like v1.36.6+k3s1 — got: $K3S_VERSION" >&2
  exit 2
fi
k3s_major="${BASH_REMATCH[1]}"
k3s_minor="${BASH_REMATCH[2]}"
if [[ "$k3s_major" -lt 1 ]]; then
  echo "k3s $K3S_VERSION is too old: v1.30+ is required (ValidatingAdmissionPolicy admissionregistration.k8s.io/v1)" >&2
  exit 2
fi
if [[ "$k3s_major" -eq 1 && "$k3s_minor" -lt 30 ]]; then
  echo "k3s $K3S_VERSION is too old: v1.30+ is required (ValidatingAdmissionPolicy admissionregistration.k8s.io/v1)" >&2
  exit 2
fi

[[ -f "$PROFILES_FILE" ]] || { echo "profiles.json not found: $PROFILES_FILE" >&2; exit 2; }
[[ -f "$DEVICE_PLUGIN_YAML" ]] || { echo "device plugin manifest not found: $DEVICE_PLUGIN_YAML" >&2; exit 2; }
for f in $SPARK_FILES; do
  [[ -f "$SCRIPT_DIR/$f" ]] || { echo "spark payload file missing: $SCRIPT_DIR/$f" >&2; exit 2; }
done
[[ -d "$SCRIPT_DIR/k8s" ]] || { echo "k8s/ not found next to this script" >&2; exit 2; }

# The device plugin image ref comes from the manifest (never hard-coded here).
DEVICE_PLUGIN_IMAGE="$(sed -n 's/^[[:space:]]*-[[:space:]]*image:[[:space:]]*//p' \
  "$DEVICE_PLUGIN_YAML" | head -n 1)"
if [[ -z "$DEVICE_PLUGIN_IMAGE" ]]; then
  echo "could not read the device plugin image from $DEVICE_PLUGIN_YAML" >&2
  exit 2
fi

# Profile table: "<name> <model>" per line.
profile_table="$(python3 - "$PROFILES_FILE" <<'PYEOF'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
except (OSError, ValueError) as e:
    sys.exit(f"cannot read profiles: {e}")
for name in sorted(data):
    print(name, data[name]["model"])
PYEOF
)"

selected_pairs=""
if [[ "$PROFILES_SEL" == "all" ]]; then
  selected_pairs="$profile_table"
else
  for p in $(printf '%s' "$PROFILES_SEL" | tr ',' ' '); do
    line="$(printf '%s\n' "$profile_table" | awk -v n="$p" '$1 == n {print; exit}')"
    if [[ -z "$line" ]]; then
      echo "unknown profile: $p (known: $(printf '%s\n' "$profile_table" | awk '{printf "%s ", $1}'))" >&2
      exit 2
    fi
    selected_pairs="${selected_pairs}${line}"$'\n'
  done
fi

# tiktoken encodings are needed to serve any openai/gpt-oss model offline.
need_tiktoken=0
while IFS=' ' read -r pname pmodel; do
  [[ -z "$pname" ]] && continue
  case "$pmodel" in
    openai/gpt-oss*) need_tiktoken=1 ;;
  esac
done <<< "$selected_pairs"

# ------------------------------------------------------------- the bundle ----

if [[ -d "$OUT" ]]; then
  entries="$(ls -A "$OUT")"
  if [[ -n "$entries" && $RESUME -eq 0 ]]; then
    echo "refusing to pack into non-empty $OUT (use --resume to continue a partial bundle)" >&2
    exit 2
  fi
fi
if [[ $DRY_RUN -eq 0 ]]; then
  mkdir -p "$OUT"
fi

finish_component() {  # name partial final
  local name="$1" partial="$2" final="$3"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "+ mv $partial $final"
    echo "+ touch $OUT/.done-$name"
    return 0
  fi
  rm -rf "$final"
  mv "$partial" "$final"
  touch "$OUT/.done-$name"
  note "component $name done"
}

# ------------------------------------------------------------- k3s ----

pack_k3s() {
  local ver_url="${K3S_VERSION//+/%2B}"
  local rel="https://github.com/k3s-io/k3s/releases/download/$ver_url"
  if [[ $DRY_RUN -eq 0 ]]; then
    rm -rf "$OUT/k3s.partial" "$OUT/k3s"
    mkdir -p "$OUT/k3s.partial"
  fi
  fetch "$rel/k3s-arm64" "$OUT/k3s.partial/k3s-arm64"
  fetch "$rel/k3s-airgap-images-arm64.tar.zst" \
        "$OUT/k3s.partial/k3s-airgap-images-arm64.tar.zst"
  fetch "$rel/sha256sum-arm64.txt" "$OUT/k3s.partial/sha256sum-arm64.txt"
  fetch "https://raw.githubusercontent.com/k3s-io/k3s/$ver_url/install.sh" \
        "$OUT/k3s.partial/install.sh"
  run chmod +x "$OUT/k3s.partial/install.sh"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "+ python3 verify k3s-arm64 and k3s-airgap-images-arm64.tar.zst against sha256sum-arm64.txt"
  else
    python3 - "$OUT/k3s.partial" <<'PYEOF'
import hashlib
import sys

d = sys.argv[1]
want = {}
with open(f"{d}/sha256sum-arm64.txt", encoding="utf-8") as f:
    for raw in f:
        parts = raw.split()
        if len(parts) == 2:
            want[parts[1]] = parts[0]
bad = []
for name in ("k3s-arm64", "k3s-airgap-images-arm64.tar.zst"):
    if name not in want:
        bad.append(f"{name}: not listed in sha256sum-arm64.txt")
        continue
    h = hashlib.sha256()
    with open(f"{d}/{name}", "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    if h.hexdigest() != want[name]:
        bad.append(f"{name}: sha256 mismatch (want {want[name][:12]}, "
                   f"got {h.hexdigest()[:12]})")
if bad:
    print("k3s release asset verification failed:", file=sys.stderr)
    for b in bad:
        print(f"  - {b}", file=sys.stderr)
    sys.exit(1)
PYEOF
  fi
  finish_component k3s "$OUT/k3s.partial" "$OUT/k3s"
}

# ------------------------------------------------------------- images ----

pack_one_image() {  # ref tarname
  local ref="$1" tarname="$2" arch=""
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "+ docker image inspect $ref (presence probe)"
    echo "+ docker image inspect --format {{.Architecture}} $ref (must be arm64)"
    echo "+ docker save -o $OUT/images.partial/$tarname $ref"
    echo "+ record $tarname $ref <image id> in images.partial/IMAGE_IDS"
    return 0
  fi
  if ! docker image inspect "$ref" >/dev/null 2>&1; then
    run docker pull --platform linux/arm64 "$ref"
  fi
  arch="$(docker image inspect --format '{{.Architecture}}' "$ref")"
  if [[ "$arch" != "arm64" ]]; then
    echo "image $ref has architecture '$arch', expected arm64" >&2
    exit 1
  fi
  run docker save -o "$OUT/images.partial/$tarname" "$ref"
  # Record the id next to the tar so MANIFEST regeneration on --resume does
  # not need the local docker daemon (the image may have been pruned).
  local image_id
  image_id="$(docker image inspect --format '{{.Id}}' "$ref")"
  printf '%s\t%s\t%s\n' "$tarname" "$ref" "$image_id" \
    >> "$OUT/images.partial/IMAGE_IDS"
}

pack_images() {
  if [[ $DRY_RUN -eq 0 ]]; then
    rm -rf "$OUT/images.partial" "$OUT/images"
    mkdir -p "$OUT/images.partial"
    : > "$OUT/images.partial/IMAGE_IDS"
  fi
  pack_one_image "$VLLM_IMAGE" vllm.tar
  pack_one_image "$DEVICE_PLUGIN_IMAGE" k8s-device-plugin.tar
  finish_component images "$OUT/images.partial" "$OUT/images"
}

# ------------------------------------------------------------- models ----
# HF cache layout: hub/models--<org>--<name>/{blobs,snapshots,refs}. Snapshot
# files are SYMLINKS into ../../blobs/<sha> — they must stay symlinks in the
# bundle (never a dereferencing copy). A local cache entry is copied file by
# file: refs/main, the snapshot symlinks (exact link text preserved) and only
# the blobs they reference. Other revisions, *.incomplete blobs and .locks
# never make it into the bundle.

copy_model_from_cache() {  # src_models_dir dest_cache_root exclude_csv
  # exit 0 = copied; exit 3 = cache entry unusable for this model (caller
  # falls back to a download); anything else = hard failure.
  python3 - "$1" "$2" "$3" <<'PYEOF'
import fnmatch
import os
import shutil
import sys

src, dest_root, csv = sys.argv[1], sys.argv[2], sys.argv[3]
excludes = [] if csv == "-" else [e for e in csv.split(",") if e]
mdir = os.path.basename(os.path.normpath(src))
dest = os.path.join(dest_root, mdir)
blobs_dir = os.path.normpath(os.path.join(src, "blobs"))

refs = os.path.join(src, "refs", "main")
if not os.path.isfile(refs):
    print(f"  - no refs/main under {src}", file=sys.stderr)
    sys.exit(3)
with open(refs, encoding="utf-8") as f:
    rev = f.read().strip()
snap = os.path.join(src, "snapshots", rev) if rev else ""
if not rev or not os.path.isdir(snap):
    print(f"  - snapshot dir for revision {rev!r} missing", file=sys.stderr)
    sys.exit(3)


def excluded(rel):
    return any(fnmatch.fnmatch(rel, pat) or fnmatch.fnmatch(rel, pat + "/*")
               for pat in excludes)


problems = []
kept = []  # (rel path under the snapshot, link text, target blob path)
for dirpath, _, filenames in os.walk(snap):
    for name in filenames:
        s = os.path.join(dirpath, name)
        rel = os.path.relpath(s, snap)
        if excluded(rel):
            continue
        if not os.path.islink(s):
            problems.append(f"{rel}: not a symlink")
            continue
        text = os.readlink(s)
        if text.startswith("/"):
            problems.append(f"{rel}: symlink target is absolute")
            continue
        target = os.path.normpath(os.path.join(os.path.dirname(s), text))
        if target == blobs_dir or not target.startswith(blobs_dir + os.sep):
            problems.append(f"{rel}: symlink does not resolve inside blobs/")
            continue
        if not os.path.isfile(target) or os.path.islink(target):
            problems.append(f"{rel}: target blob missing or not a regular file")
            continue
        kept.append((rel, text, target))

if problems:
    print(f"local HF cache entry {mdir} is unusable "
          "(dangling or escaping symlinks):", file=sys.stderr)
    for p in problems[:10]:
        print(p, file=sys.stderr)
    shutil.rmtree(dest, ignore_errors=True)
    sys.exit(3)

snap_dest = os.path.join(dest, "snapshots", rev)
os.makedirs(os.path.join(dest, "refs"), exist_ok=True)
os.makedirs(snap_dest, exist_ok=True)
os.makedirs(os.path.join(dest, "blobs"), exist_ok=True)
with open(os.path.join(dest, "refs", "main"), "w", encoding="utf-8") as f:
    f.write(rev)
for rel, text, target in kept:
    d = os.path.dirname(rel)
    if d:
        os.makedirs(os.path.join(snap_dest, d), exist_ok=True)
    os.symlink(text, os.path.join(snap_dest, rel))
    blob_dest = os.path.join(dest, "blobs", os.path.basename(target))
    if not os.path.lexists(blob_dest):
        shutil.copy2(target, blob_dest)
sys.exit(0)
PYEOF
}

download_model() {  # model_id dest_cache_root — downloads INTO a per-model
  # staging dir that survives between runs, so `hf download` can resume.
  local model="$1" dest="$2" csv g
  csv="$(exclude_csv)"
  local -a cmd
  if command -v hf >/dev/null 2>&1; then
    cmd=(hf download "$model" --cache-dir "$dest")
    if [[ "$csv" != "-" ]]; then
      for g in "${EXCLUDE_GLOBS[@]}"; do
        cmd+=(--exclude "$g")
      done
    fi
    run "${cmd[@]}"
    return 0
  fi
  if command -v huggingface-cli >/dev/null 2>&1; then
    cmd=(huggingface-cli download "$model" --cache-dir "$dest")
    if [[ "$csv" != "-" ]]; then
      for g in "${EXCLUDE_GLOBS[@]}"; do
        cmd+=(--exclude "$g")
      done
    fi
    run "${cmd[@]}"
    return 0
  fi
  # Docker fallback: run as the invoking user (no root-owned files) and pass
  # HF_TOKEN by NAME only (-e HF_TOKEN) — the value never enters argv.
  cmd=(docker run --rm --user "$(id -u):$(id -g)" -v "$dest:/hf"
      -e HF_HUB_CACHE=/hf)
  if [[ -n "${HF_TOKEN:-}" ]]; then
    cmd+=(-e HF_TOKEN)
  fi
  cmd+=("$VLLM_IMAGE" python3 -c 'import sys
from huggingface_hub import snapshot_download
patterns = [] if sys.argv[2] == "-" else sys.argv[2].split(",")
if patterns:
    snapshot_download(sys.argv[1], ignore_patterns=patterns)
else:
    snapshot_download(sys.argv[1])' "$model" "$csv")
  run "${cmd[@]}"
}

pack_one_model() {  # pname pmodel
  local pname="$1" pmodel="$2"
  local mdir="models--${pmodel//\//--}"
  local marker="$OUT/.done-model-$pname"
  local staged="$OUT/hf.partial/hub"
  if [[ $RESUME -eq 1 && -f "$marker" && -d "$staged/$mdir" ]]; then
    note "$pname: model already packed; skipping"
    return 0
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    local src="$HF_CACHE/hub/$mdir"
    if [[ -f "$src/refs/main" ]]; then
      echo "+ python3 copy $mdir from the local HF cache (refs/main + snapshot symlinks + referenced blobs only)"
    else
      echo "+ stage $mdir into $staged/$mdir.partial, then rename into place"
      download_model "$pmodel" "$staged/$mdir.partial"
    fi
    echo "+ touch $marker"
    return 0
  fi
  local partial_dir="$staged/$mdir.partial"
  local src="$HF_CACHE/hub/$mdir"
  local csv copied=0
  csv="$(exclude_csv)"
  if [[ -f "$src/refs/main" ]]; then
    note "$pname: copying $mdir from the local HF cache"
    # The local copy is deterministic — start it clean. The download path
    # below does NOT wipe the staging dir so `hf download` can resume.
    rm -rf "$partial_dir"
    mkdir -p "$partial_dir"
    if copy_model_from_cache "$src" "$partial_dir" "$csv"; then
      copied=1
    else
      local rc=$?
      if [[ $rc -ne 3 ]]; then
        echo "copying $mdir from the local HF cache failed" >&2
        exit "$rc"
      fi
      note "$pname: local cache entry unusable — downloading instead"
      rm -rf "$partial_dir"
      mkdir -p "$partial_dir"
    fi
  else
    note "$pname: $pmodel not in $HF_CACHE — downloading"
  fi
  if [[ $copied -eq 0 ]]; then
    # The staging dir keeps the download resumable across --resume runs.
    mkdir -p "$partial_dir"
    download_model "$pmodel" "$partial_dir"
    if [[ ! -f "$partial_dir/$mdir/refs/main" ]]; then
      echo "download of $pmodel did not produce $mdir/refs/main in the staging dir" >&2
      exit 1
    fi
    mv "$partial_dir/$mdir" "$staged/$mdir"
    rmdir "$partial_dir" 2>/dev/null || rm -rf "$partial_dir"
  else
    mv "$partial_dir/$mdir" "$staged/$mdir"
    rmdir "$partial_dir" 2>/dev/null || rm -rf "$partial_dir"
  fi
  touch "$marker"
}

pack_models() {
  local pname pmodel
  if [[ $DRY_RUN -eq 1 ]]; then
    while IFS=' ' read -r pname pmodel; do
      [[ -z "$pname" ]] && continue
      pack_one_model "$pname" "$pmodel"
    done <<< "$selected_pairs"
    echo "+ mv $OUT/hf.partial/hub $OUT/hf/hub (hf/tiktoken untouched)"
    echo "+ touch $OUT/.done-models"
    return 0
  fi
  if [[ $RESUME -eq 0 ]]; then
    rm -rf "$OUT/hf.partial"
    rm -rf "$OUT/hf/hub"   # never the whole hf/ — tiktoken survives (P5)
  fi
  mkdir -p "$OUT/hf.partial/hub"
  while IFS=' ' read -r pname pmodel; do
    [[ -z "$pname" ]] && continue
    pack_one_model "$pname" "$pmodel"
  done <<< "$selected_pairs"
  # All selected models complete: move the hub into place without touching
  # $OUT/hf/tiktoken.
  rm -rf "$OUT/hf/hub"
  mkdir -p "$OUT/hf"
  mv "$OUT/hf.partial/hub" "$OUT/hf/hub"
  rmdir "$OUT/hf.partial" 2>/dev/null || rm -rf "$OUT/hf.partial"
  touch "$OUT/.done-models"
  note "component models done"
}

# ------------------------------------------------------------- tiktoken ----

pack_tiktoken() {
  if [[ $DRY_RUN -eq 0 ]]; then
    rm -rf "$OUT/hf/tiktoken.partial" "$OUT/hf/tiktoken"
    mkdir -p "$OUT/hf/tiktoken.partial"
  fi
  fetch "https://openaipublic.blob.core.windows.net/encodings/o200k_base.tiktoken" \
        "$OUT/hf/tiktoken.partial/o200k_base.tiktoken"
  fetch "https://openaipublic.blob.core.windows.net/encodings/cl100k_base.tiktoken" \
        "$OUT/hf/tiktoken.partial/cl100k_base.tiktoken"
  finish_component tiktoken "$OUT/hf/tiktoken.partial" "$OUT/hf/tiktoken"
}

# ------------------------------------------------------------- spark ----

pack_spark() {
  if [[ $DRY_RUN -eq 0 ]]; then
    rm -rf "$OUT/spark.partial" "$OUT/spark"
    mkdir -p "$OUT/spark.partial"
  fi
  local f
  for f in $SPARK_FILES; do
    run cp "$SCRIPT_DIR/$f" "$OUT/spark.partial/$f"
  done
  run cp -R "$SCRIPT_DIR/k8s" "$OUT/spark.partial/k8s"
  finish_component spark "$OUT/spark.partial" "$OUT/spark"
}

# ------------------------------------------------------------- run ----

if [[ $RESUME -eq 1 ]]; then
  note "--resume: reusing $OUT, skipping completed components"
fi

if [[ $NO_K3S -eq 1 ]]; then
  note "k3s component skipped (--no-k3s)"
elif [[ $RESUME -eq 1 && -f "$OUT/.done-k3s" ]]; then
  note "k3s already packed; skipping"
else
  pack_k3s
fi

if [[ $NO_IMAGES -eq 1 ]]; then
  note "images component skipped (--no-images)"
elif [[ $RESUME -eq 1 && -f "$OUT/.done-images" ]]; then
  note "images already packed; skipping"
else
  pack_images
fi

if [[ $NO_MODELS -eq 1 ]]; then
  note "models component skipped (--no-models)"
elif [[ $RESUME -eq 1 && -f "$OUT/.done-models" ]]; then
  note "models already packed; skipping"
else
  pack_models
fi

if [[ $NO_MODELS -eq 1 || $need_tiktoken -eq 0 ]]; then
  note "tiktoken component skipped (no gpt-oss profile packed)"
elif [[ $RESUME -eq 1 && -f "$OUT/.done-tiktoken" ]]; then
  note "tiktoken already packed; skipping"
else
  pack_tiktoken
fi

if [[ $RESUME -eq 1 && -f "$OUT/.done-spark" ]]; then
  note "spark already packed; skipping"
else
  pack_spark
fi

# ------------------------------------------------------------- finalize ----

if [[ $DRY_RUN -eq 1 ]]; then
  note "dry-run complete; nothing was created"
  exit 0
fi

# Secret guard: a bundle is moved between machines and plugged into air-gapped
# hosts — it must not become a secret carrier. Placeholders (empty value,
# <...>, change-me-*) are fine; real assignments are not.
echo "+ python3 secret guard scan (spark/ + MANIFEST.json + file names)"
python3 - "$OUT" <<'PYEOF'
import os
import re
import sys

root = sys.argv[1]
pat = re.compile(
    r"^\s*(?:export\s+)?(SWITCH_TOKEN|VLLM_API_KEY|HF_TOKEN)=(.*)$")


def is_placeholder(value):
    v = value.strip().strip("\"'")
    return (not v) or v.startswith("<") or v.startswith("change-me") \
        or set(v) == {"."}


problems = []
targets = []
spark_dir = os.path.join(root, "spark")
if os.path.isdir(spark_dir):
    targets.append(spark_dir)
manifest = os.path.join(root, "MANIFEST.json")
if os.path.isfile(manifest):
    targets.append(manifest)
for base in targets:
    if os.path.isfile(base):
        files = [base]
    else:
        files = [os.path.join(dp, name)
                 for dp, _, names in os.walk(base)
                 for name in names]
    for path in files:
        if os.path.islink(path) or not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8", errors="replace") as f:
            for lineno, line in enumerate(f, 1):
                m = pat.match(line)
                if m and not is_placeholder(m.group(2)):
                    problems.append(
                        f"{os.path.relpath(path, root)}:{lineno}: "
                        f"{m.group(1)} carries a non-placeholder value")
for dp, _, fn in os.walk(root):
    for name in fn:
        if name == "env" or name.endswith(".key") or name.startswith("token"):
            problems.append(
                "suspicious file name in bundle: "
                f"{os.path.relpath(os.path.join(dp, name), root)}")
if problems:
    print("secret guard: refusing to finish this bundle:", file=sys.stderr)
    for p in problems[:10]:
        print(f"  - {p}", file=sys.stderr)
    sys.exit(1)
PYEOF

# Image ids: read from images/IMAGE_IDS (written when the tars were saved) so
# a --resume finalize works even after the local docker image was pruned.
# Only if that file is missing do we fall back to docker image inspect.
read_image_id() {  # tarname -> id (empty when unknown)
  local ids="$OUT/images/IMAGE_IDS"
  [[ -f "$ids" ]] || return 0
  awk -F'\t' -v t="$1" '$1 == t {print $3; exit}' "$ids"
}

vllm_id=""
dp_id=""
if [[ -f "$OUT/images/vllm.tar" ]]; then
  vllm_id="$(read_image_id vllm.tar)"
  if [[ -z "$vllm_id" ]]; then
    vllm_id="$(docker image inspect --format '{{.Id}}' "$VLLM_IMAGE")"
  fi
fi
if [[ -f "$OUT/images/k8s-device-plugin.tar" ]]; then
  dp_id="$(read_image_id k8s-device-plugin.tar)"
  if [[ -z "$dp_id" ]]; then
    dp_id="$(docker image inspect --format '{{.Id}}' "$DEVICE_PLUGIN_IMAGE")"
  fi
fi

echo "+ python3 write MANIFEST.json and SHA256SUMS"
python3 - "$OUT" "$K3S_VERSION" "$VLLM_IMAGE" "$vllm_id" \
          "$DEVICE_PLUGIN_IMAGE" "$dp_id" "$selected_pairs" "$(exclude_csv)" <<'PYEOF'
import datetime
import hashlib
import json
import os
import sys

(root, k3s_version, vllm_ref, vllm_id, dp_ref, dp_id, pairs_text,
 excludes_csv) = sys.argv[1:9]
pairs = [tuple(line.split(" ", 1)) for line in pairs_text.splitlines()
         if line.strip()]
excludes = [] if excludes_csv == "-" else \
    [e for e in excludes_csv.split(",") if e]

# Refuse to finalize an incomplete bundle: any *.partial directory left under
# the root means a component or model did not finish.
partial_left = []
for dirpath, dirnames, _ in os.walk(root):
    for d in dirnames:
        if ".partial" in d:
            partial_left.append(
                os.path.relpath(os.path.join(dirpath, d), root))
if partial_left:
    print("refusing to write MANIFEST/SHA256SUMS: incomplete components "
          "remain:", file=sys.stderr)
    for p in sorted(partial_left)[:10]:
        print(f"  - {p}", file=sys.stderr)
    sys.exit(1)

images = []
for ref, image_id, rel in ((vllm_ref, vllm_id, "images/vllm.tar"),
                           (dp_ref, dp_id, "images/k8s-device-plugin.tar")):
    if os.path.isfile(os.path.join(root, rel)):
        images.append({"ref": ref, "file": rel, "image_id": image_id})

models = []
hub = os.path.join(root, "hf", "hub")
if os.path.isdir(hub):
    for name, model in pairs:
        refs = os.path.join(hub, "models--" + model.replace("/", "--"),
                            "refs", "main")
        rev = ""
        if os.path.isfile(refs):
            with open(refs, encoding="utf-8") as f:
                rev = f.read().strip()
        models.append({"profile": name, "model": model, "revision": rev,
                       "exclude": excludes})

manifest = {
    "format": 1,
    "created": datetime.datetime.now(
        datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "arch": "arm64",
    "k3s_version": k3s_version,
    "images": images,
    "models": models,
    "tiktoken": os.path.isdir(os.path.join(root, "hf", "tiktoken")),
}
with open(os.path.join(root, "MANIFEST.json"), "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")

lines = []
for dp, _, fn in os.walk(root):
    for name in fn:
        path = os.path.join(dp, name)
        rel = os.path.relpath(path, root)
        if rel == "SHA256SUMS" or os.path.islink(path):
            continue  # symlinks are preserved, never hashed
        if os.path.basename(rel).startswith("."):
            continue  # resume markers and other dot files
        if any(".partial" in part for part in rel.split(os.sep)):
            continue  # staging paths never reach SHA256SUMS
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 16), b""):
                h.update(chunk)
        lines.append(f"{h.hexdigest()}  {rel}")
lines.sort(key=lambda line: line.split("  ", 1)[1])
with open(os.path.join(root, "SHA256SUMS"), "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
PYEOF

note "bundle complete: $OUT"
for comp in k3s images hf spark; do
  if [[ -d "$OUT/$comp" ]]; then
    du -sh "$OUT/$comp"
  fi
done
du -sh "$OUT"
