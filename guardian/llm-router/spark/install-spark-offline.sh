#!/usr/bin/env bash
# install-spark-offline.sh — install the offline (air-gapped) bundle that
# pack-spark-offline.sh built on a connected arm64 host. Runs on the DGX
# Spark and reads ONLY the bundle directory: every file it touches comes from
# --bundle, and it must never gain a way to reach the network (the test suite
# statically rejects the usual suspects in this source, comments included).
#
#   ./install-spark-offline.sh --bundle /mnt/usb/spark-bundle            # = --verify
#   ./install-spark-offline.sh --bundle DIR --verify
#   ./install-spark-offline.sh --bundle DIR --install-k3s
#   ./install-spark-offline.sh --bundle DIR --load-images
#   ./install-spark-offline.sh --bundle DIR --load-models
#   ./install-spark-offline.sh --bundle DIR --all [--dry-run]
#
# --all runs verify, install-k3s, load-images and load-models in that order;
# verify (read-only) always runs first for every action. --dry-run keeps
# verify and prints everything else as "+ ..." lines without changing
# anything.
#
# The NVIDIA container toolkit is NOT part of the bundle: k3s auto-detects
# nvidia-container-runtime from the host, so DGX OS must already provide it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BUNDLE=""
DO_VERIFY=0
DO_K3S=0
DO_IMAGES=0
DO_MODELS=0
DRY_RUN=0

HF_CACHE_DIR="${HF_CACHE_DIR:-$HOME/.cache/huggingface}"

usage() {
  cat <<'EOF'
Usage: install-spark-offline.sh --bundle DIR [--verify] [--install-k3s]
                                [--load-images] [--load-models] [--all]
                                [--dry-run] [-h|--help]

  (no action flag)  same as --verify
  --verify          read-only integrity check (always runs first, for every
                    action): MANIFEST format/arch, host arch, SHA256SUMS of
                    every listed file, every MANIFEST-referenced file present
  --install-k3s     install the bundled k3s binary + airgap images as a
                    systemd service (needs passwordless sudo and
                    nvidia-container-runtime on the host)
  --load-images     import the bundled container image tars into containerd
  --load-models     merge the bundled HF cache (models + tiktoken) into
                    HF_CACHE_DIR, preserving symlinks and never overwriting
                    a differing file
  --all             verify, install-k3s, load-images, load-models (in order)
  --dry-run         verify still runs; every other command is printed with a
                    leading "+ " and NOT executed

Environment: HF_CACHE_DIR (default $HOME/.cache/huggingface).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle) BUNDLE="${2:?--bundle needs a value}"; shift 2 ;;
    --verify) DO_VERIFY=1; shift ;;
    --install-k3s) DO_K3S=1; shift ;;
    --load-images) DO_IMAGES=1; shift ;;
    --load-models) DO_MODELS=1; shift ;;
    --all) DO_VERIFY=1; DO_K3S=1; DO_IMAGES=1; DO_MODELS=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$BUNDLE" ]]; then
  echo "--bundle DIR is required" >&2
  exit 2
fi
BUNDLE="$(cd "$BUNDLE" && pwd)"

if [[ $((DO_VERIFY + DO_K3S + DO_IMAGES + DO_MODELS)) -eq 0 ]]; then
  DO_VERIFY=1
fi

note() { echo "[install-offline] $*"; }

run() {
  echo "+ $*"
  if [[ $DRY_RUN -eq 0 ]]; then
    "$@"
  fi
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

manifest_json() {
  python3 -c 'import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    print(json.dumps(json.load(f)))' "$BUNDLE/MANIFEST.json"
}

manifest_field() {  # key -> value (empty string when missing)
  manifest_json | python3 -c 'import json, sys
man = json.loads(sys.stdin.read())
print(man.get(sys.argv[1], "") or "")' "$1"
}

# Symlink safety for the untrusted bundle: inside every models--* dir, the
# only regular files allowed are under blobs/ and refs/; snapshots/ may hold
# nothing but RELATIVE symlinks that resolve INSIDE the same model's blobs/
# to an existing regular file. Reports every violation, then fails.
check_bundle_models() {
  python3 - "$BUNDLE/hf/hub" <<'PYEOF'
import os
import sys

hub = sys.argv[1]
problems = []


def add(msg):
    if len(problems) < 12:  # report all we can, capped for readability
        problems.append(msg)


if not os.path.isdir(hub):
    sys.exit(0)
for name in sorted(os.listdir(hub)):
    if not name.startswith("models--"):
        continue
    mdir = os.path.join(hub, name)
    if os.path.islink(mdir) or not os.path.isdir(mdir):
        add(f"{name}: models-- entry is not a real directory")
        continue
    blobs = os.path.normpath(os.path.join(mdir, "blobs"))
    for entry in os.listdir(mdir):
        top = os.path.join(mdir, entry)
        if os.path.islink(top):
            add(f"{name}: symlink at the top level: {entry}")
        elif os.path.isfile(top):
            add(f"{name}: unexpected regular file at the top level: {entry}")
    for dirpath, dirnames, filenames in os.walk(mdir):
        rel_dir = os.path.relpath(dirpath, mdir)
        for dname in dirnames:
            if os.path.islink(os.path.join(dirpath, dname)):
                rel = os.path.join(rel_dir, dname) if rel_dir != "." else dname
                add(f"{name}: symlinked directory: {rel}")
        for fname in filenames:
            path = os.path.join(dirpath, fname)
            rel = os.path.join(rel_dir, fname) if rel_dir != "." else fname
            top = rel.split(os.sep)[0]
            if os.path.islink(path):
                if top != "snapshots":
                    add(f"{name}: symlink outside snapshots/: {rel}")
                    continue
                text = os.readlink(path)
                if text.startswith("/"):
                    add(f"{name}/{rel}: absolute symlink target")
                    continue
                target = os.path.normpath(
                    os.path.join(os.path.dirname(path), text))
                if target == blobs or not target.startswith(blobs + os.sep):
                    add(f"{name}/{rel}: symlink escapes the model's blobs/")
                    continue
                if not os.path.isfile(target) or os.path.islink(target):
                    add(f"{name}/{rel}: target blob missing or not a regular file")
                    continue
            elif top == "snapshots":
                add(f"{name}/{rel}: regular file inside snapshots/ "
                    "(must be a relative symlink into blobs/)")
            elif top not in ("blobs", "refs"):
                add(f"{name}/{rel}: regular file outside blobs/ and refs/")
if problems:
    print("unsafe HF cache in the bundle:", file=sys.stderr)
    for p in problems:
        print(f"  - {p}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

# ---------------------------------------------------------------- verify ----
# Read-only; runs before every action, --dry-run included.

verify_bundle() {
  [[ -f "$BUNDLE/MANIFEST.json" ]] || fail "$BUNDLE/MANIFEST.json not found"
  [[ -f "$BUNDLE/SHA256SUMS" ]] || fail "$BUNDLE/SHA256SUMS not found"

  local machine_arch
  machine_arch="$(uname -m)"
  case "$machine_arch" in
    aarch64|arm64) ;;
    *) fail "host arch is $machine_arch; this bundle is arm64-only" ;;
  esac

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "+ python3 verify MANIFEST.json + SHA256SUMS (read-only, always runs)"
  fi
  python3 - "$BUNDLE" <<'PYEOF'
import hashlib
import json
import os
import sys

bundle = sys.argv[1]
problems = []


def add(msg):
    if len(problems) < 8:  # list the first mismatches, not all of them
        problems.append(msg)


man = None
try:
    with open(os.path.join(bundle, "MANIFEST.json"),
              encoding="utf-8") as f:
        man = json.load(f)
except OSError as e:
    add(f"MANIFEST.json unreadable: {e}")
except ValueError as e:
    add(f"MANIFEST.json is not valid JSON: {e}")

if man is not None:
    if man.get("format") != 1:
        add(f"MANIFEST format is {man.get('format')!r}, expected 1")
    if man.get("arch") != "arm64":
        add(f"MANIFEST arch is {man.get('arch')!r}, expected arm64")

checked = 0
try:
    with open(os.path.join(bundle, "SHA256SUMS"),
              encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\n")
            if not line:
                continue
            parts = line.split("  ", 1)
            if len(parts) != 2 or len(parts[0]) != 64:
                add(f"SHA256SUMS line is malformed: {line[:60]}")
                continue
            digest, rel = parts
            path = os.path.join(bundle, rel)
            if os.path.islink(path):
                add(f"SHA256SUMS lists a symlink (never hashed): {rel}")
                continue
            if not os.path.isfile(path):
                add(f"file listed in SHA256SUMS is missing: {rel}")
                continue
            h = hashlib.sha256()
            with open(path, "rb") as fh:
                for chunk in iter(lambda: fh.read(1 << 16), b""):
                    h.update(chunk)
            if h.hexdigest() != digest:
                add(f"checksum mismatch: {rel}")
            checked += 1
except OSError as e:
    add(f"SHA256SUMS unreadable: {e}")

if man is not None:
    if checked == 0 and not problems:
        add("SHA256SUMS checked no files")
    for img in man.get("images") or []:
        rel = img.get("file", "")
        if rel and not os.path.isfile(os.path.join(bundle, rel)):
            add(f"image tar listed in MANIFEST is missing: {rel}")
    for m in man.get("models") or []:
        mdir = "models--" + m.get("model", "").replace("/", "--")
        base = os.path.join(bundle, "hf", "hub", mdir)
        refs = os.path.join(base, "refs", "main")
        if not os.path.isfile(refs):
            add(f"model cache incomplete (refs/main missing): {mdir}")
            continue
        with open(refs, encoding="utf-8") as f:
            rev = f.read().strip()
        if rev and not os.path.isdir(os.path.join(base, "snapshots", rev)):
            add(f"model snapshot dir missing: {mdir}/snapshots/{rev}")
    if man.get("tiktoken"):
        for enc in ("o200k_base.tiktoken", "cl100k_base.tiktoken"):
            rel = os.path.join("hf", "tiktoken", enc)
            if not os.path.isfile(os.path.join(bundle, rel)):
                add(f"tiktoken encoding missing: {rel}")

if problems:
    print("bundle verification failed:", file=sys.stderr)
    for p in problems:
        print(f"  - {p}", file=sys.stderr)
    sys.exit(1)
print(f"verified: {checked} file(s) match SHA256SUMS")
PYEOF
  echo "+ python3 check every HF snapshot symlink (bundle is untrusted input)"
  check_bundle_models
}

verify_bundle

# ------------------------------------------------------------ install-k3s ----

preflight_install_k3s() {
  local k3s_ver
  k3s_ver="$(manifest_field k3s_version)"
  [[ -n "$k3s_ver" ]] || fail "MANIFEST.json has no k3s_version"
  [[ -f "$BUNDLE/k3s/k3s-arm64" ]] || fail "$BUNDLE/k3s/k3s-arm64 missing (was the bundle packed with --no-k3s?)"
  [[ -f "$BUNDLE/k3s/install.sh" ]] || fail "$BUNDLE/k3s/install.sh missing"

  sudo -n true || fail "passwordless sudo is required for --install-k3s"
  if ! command -v nvidia-container-runtime >/dev/null 2>&1; then
    fail "nvidia-container-runtime not found on PATH: the NVIDIA container \
toolkit is NOT part of the bundle (DGX OS provides it); install it first"
  fi

  if command -v k3s >/dev/null 2>&1; then
    local installed
    # `k3s --version` prints 2 lines ("k3s version vX (hash)" then a go
    # version line) — parse the version token from line 1 only.
    installed="$(k3s --version 2>/dev/null | awk 'NR==1{print $3}')"
    if [[ "$installed" == "$k3s_ver" ]]; then
      note "k3s $k3s_ver is already installed; skipping --install-k3s"
      return 1
    fi
    fail "refusing to install over an existing k3s: installed '$installed' != bundle '$k3s_ver' (uninstall it first)"
  fi

  # Disk-space preflight: the airgap images tar plus every workload image tar
  # will be sudo-copied under /var/lib/rancher/k3s/agent/images — require the
  # total plus 10% headroom BEFORE any sudo write happens.
  local need_kb avail_kb probe="/var/lib/rancher/k3s/agent/images"
  need_kb="$(python3 - "$BUNDLE" <<'PYEOF'
import math
import os
import sys

bundle = sys.argv[1]
total = 0
airgap = os.path.join(bundle, "k3s", "k3s-airgap-images-arm64.tar.zst")
if os.path.isfile(airgap):
    total += os.path.getsize(airgap)
imgdir = os.path.join(bundle, "images")
if os.path.isdir(imgdir):
    for name in os.listdir(imgdir):
        path = os.path.join(imgdir, name)
        if os.path.isfile(path):
            total += os.path.getsize(path)
print(math.ceil(total * 1.1 / 1024))
PYEOF
)"
  while [[ ! -d "$probe" && "$probe" != "/" ]]; do
    probe="$(dirname "$probe")"
  done
  avail_kb="$(df -Pk "$probe" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
  if [[ -n "$avail_kb" && "$avail_kb" -lt "$need_kb" ]]; then
    fail "not enough free space under $probe for the k3s airgap + workload images: need ${need_kb} KB (incl. 10% headroom), have ${avail_kb} KB"
  fi
  return 0
}

do_install_k3s() {
  if ! preflight_install_k3s; then
    return 0
  fi
  local k3s_ver
  k3s_ver="$(manifest_field k3s_version)"

  run sudo install -m 0755 "$BUNDLE/k3s/k3s-arm64" /usr/local/bin/k3s
  run sudo mkdir -p /var/lib/rancher/k3s/agent/images
  run sudo cp "$BUNDLE/k3s/k3s-airgap-images-arm64.tar.zst" \
      /var/lib/rancher/k3s/agent/images/
  local tar
  for tar in "$BUNDLE"/images/*.tar; do
    [[ -f "$tar" ]] || continue
    # k3s imports everything in this dir on start, so the workload images
    # ride along for free.
    run sudo cp "$tar" /var/lib/rancher/k3s/agent/images/
  done

  local dropin="/etc/systemd/system/k3s.service.d/memlock.conf"
  local dropin_content="[Service]
LimitMEMLOCK=infinity"
  run sudo mkdir -p /etc/systemd/system/k3s.service.d
  echo "+ sudo tee $dropin (LimitMEMLOCK=infinity)"
  if [[ $DRY_RUN -eq 0 ]]; then
    printf '%s\n' "$dropin_content" | sudo tee "$dropin" >/dev/null
  fi

  run sudo env INSTALL_K3S_SKIP_DOWNLOAD=true \
      INSTALL_K3S_VERSION="$k3s_ver" \
      INSTALL_K3S_EXEC="--disable traefik --write-kubeconfig-mode 600 --secrets-encryption" \
      sh "$BUNDLE/k3s/install.sh"

  # install.sh returns before the service has written its kubeconfig — poll
  # for a non-empty /etc/rancher/k3s/k3s.yaml instead of racing it.
  local max_wait="${K3S_KUBECONFIG_WAIT_SECONDS:-60}" waited=0
  echo "+ wait up to ${max_wait}s for a non-empty /etc/rancher/k3s/k3s.yaml"
  if [[ $DRY_RUN -eq 0 ]]; then
    while [[ $waited -lt $max_wait ]]; do
      if sudo test -s /etc/rancher/k3s/k3s.yaml 2>/dev/null; then
        break
      fi
      sleep 2
      waited=$((waited + 2))
    done
    if ! sudo test -s /etc/rancher/k3s/k3s.yaml 2>/dev/null; then
      fail "k3s did not write /etc/rancher/k3s/k3s.yaml within ${max_wait}s — inspect the service log, then re-run with --resume-style flags"
    fi
  fi

  # kubeconfig for the normal user: root-owned k3s.yaml copied through a
  # privileged cat into a user-owned file. The temp file is created under
  # umask 077 (subshell) so it is never group/world readable at any moment,
  # then moved into place and forced to 0600.
  run mkdir -p "$HOME/.kube"
  echo "+ sudo cat /etc/rancher/k3s/k3s.yaml > $HOME/.kube/config (umask 077, chmod 600)"
  if [[ $DRY_RUN -eq 0 ]]; then
    local tmp_config="$HOME/.kube/config.offline-tmp"
    (
      umask 077
      sudo cat /etc/rancher/k3s/k3s.yaml > "$tmp_config"
    )
    mv -f "$tmp_config" "$HOME/.kube/config"
    chmod 600 "$HOME/.kube/config"
  fi
  note "k3s $k3s_ver installed (systemd unit k3s.service). Docker containers \
were not touched."
}

# ------------------------------------------------------------ load-images ----

do_load_images() {
  local tar found
  found=0
  for tar in "$BUNDLE"/images/*.tar; do
    if [[ -f "$tar" ]]; then
      found=1
    fi
  done
  if [[ $found -eq 0 ]]; then
    note "no image tars in the bundle (--no-images pack?); nothing to import"
    return 0
  fi
  sudo -n k3s ctr version >/dev/null 2>&1 \
    || fail "cannot talk to containerd (sudo -n k3s ctr version failed)"

  for tar in "$BUNDLE"/images/*.tar; do
    [[ -f "$tar" ]] || continue
    run sudo k3s ctr -n k8s.io images import "$tar"
  done

  echo "+ sudo k3s ctr -n k8s.io images ls -q (checking every MANIFEST ref)"
  if [[ $DRY_RUN -eq 1 ]]; then
    return 0
  fi
  local ctr_list ref line found missing=0
  ctr_list="$(sudo -n k3s ctr -n k8s.io images ls -q 2>/dev/null || true)"
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    found=0
    # exact line-by-line comparison: a substring match would accept
    # "registry/repo:tag-extra" when looking for "registry/repo:tag"
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      if [[ "$line" == "$ref" ]]; then
        found=1
        break
      fi
    done <<< "$ctr_list"
    if [[ $found -ne 1 ]]; then
      echo "ERROR: $ref was not imported into containerd" >&2
      missing=1
    fi
  done < <(manifest_json | python3 -c 'import json, sys
man = json.loads(sys.stdin.read())
for img in man.get("images") or []:
    print(img.get("ref", ""))')
  if [[ $missing -ne 0 ]]; then
    fail "some MANIFEST image refs are missing from containerd"
  fi
  note "all MANIFEST image refs are present in containerd"
}

# ------------------------------------------------------------ load-models ----

merge_model_dir() {  # src dst — preserve symlinks, never overwrite a differing file
  python3 - "$1" "$2" <<'PYEOF'
import hashlib
import os
import shutil
import sys

src, dst = sys.argv[1], sys.argv[2]
errors = []
copied = skipped = 0


def same_file(a, b):
    if os.path.getsize(a) != os.path.getsize(b):
        return False
    ha, hb = hashlib.sha256(), hashlib.sha256()
    with open(a, "rb") as fa:
        for chunk in iter(lambda: fa.read(1 << 20), b""):
            ha.update(chunk)
    with open(b, "rb") as fb:
        for chunk in iter(lambda: fb.read(1 << 20), b""):
            hb.update(chunk)
    return ha.digest() == hb.digest()


for dirpath, dirnames, filenames in os.walk(src):
    rel = os.path.relpath(dirpath, src)
    target_dir = dst if rel == "." else os.path.join(dst, rel)
    os.makedirs(target_dir, exist_ok=True)
    for name in list(dirnames) + list(filenames):
        s = os.path.join(dirpath, name)
        t = os.path.join(target_dir, name)
        if os.path.islink(s):
            link = os.readlink(s)
            if os.path.lexists(t):
                if not (os.path.islink(t) and os.readlink(t) == link):
                    errors.append(f"refusing to replace {t} with a symlink")
            else:
                os.symlink(link, t)
                copied += 1
            continue
        if not os.path.isfile(s):
            continue
        if os.path.lexists(t):
            if os.path.islink(t) or not same_file(s, t):
                errors.append(
                    f"refusing to overwrite a differing file: {t}")
            else:
                skipped += 1
            continue
        shutil.copy2(s, t)
        copied += 1

if errors:
    for e in errors[:10]:
        print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
print(f"  {dst}: {copied} copied, {skipped} identical skipped")
PYEOF
}

preflight_load_models() {
  if [[ ! -d "$BUNDLE/hf/hub" ]]; then
    note "no hf/hub in the bundle (--no-models pack?); --load-models is a no-op"
    return 1
  fi
  # Walk up to the nearest EXISTING ancestor before df — df refuses to stat
  # a path whose parents do not exist yet.
  local check_dir="$HF_CACHE_DIR"
  while [[ ! -d "$check_dir" && "$check_dir" != "/" ]]; do
    check_dir="$(dirname "$check_dir")"
  done
  if [[ ! -w "$check_dir" && ! -w "$HF_CACHE_DIR" ]]; then
    fail "HF_CACHE_DIR is not writable: $HF_CACHE_DIR"
  fi
  # Count only what would actually be written: bundle files whose
  # destination does not already exist with the same size.
  local need_kb avail_kb
  need_kb="$(python3 - "$BUNDLE/hf" "$HF_CACHE_DIR" <<'PYEOF'
import math
import os
import sys

src, dst = sys.argv[1], sys.argv[2]
total = 0
for dirpath, _, filenames in os.walk(src):
    for name in filenames:
        path = os.path.join(dirpath, name)
        if os.path.islink(path):
            continue
        target = os.path.join(dst, os.path.relpath(path, src))
        if os.path.exists(target) and not os.path.islink(target) \
                and os.path.getsize(target) == os.path.getsize(path):
            continue
        total += os.path.getsize(path)
print(math.ceil(total / 1024))
PYEOF
)"
  avail_kb="$(df -Pk "$check_dir" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
  if [[ -n "$avail_kb" && "$avail_kb" -lt "$need_kb" ]]; then
    fail "not enough free space for hf/ under $check_dir: need ${need_kb} KB, have ${avail_kb} KB"
  fi
  return 0
}

do_load_models() {
  if ! preflight_load_models; then
    return 0
  fi
  # Second line of defence next to verify: never merge an unsafe layout.
  echo "+ python3 re-check HF snapshot symlinks before merging"
  check_bundle_models
  run mkdir -p "$HF_CACHE_DIR/hub"
  local mdir
  for mdir in "$BUNDLE"/hf/hub/models--*; do
    [[ -d "$mdir" ]] || continue
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "+ copy $(basename "$mdir") into $HF_CACHE_DIR/hub (symlinks preserved)"
    else
      merge_model_dir "$mdir" "$HF_CACHE_DIR/hub/$(basename "$mdir")"
    fi
  done

  if [[ -d "$BUNDLE/hf/tiktoken" ]]; then
    # the copy below creates the destination dir itself, only once every
    # file passed validation — a planted symlink creates nothing at all
    echo "+ python3 copy tiktoken files one by one (never overwrite a differing file)"
    if [[ $DRY_RUN -eq 0 ]]; then
      python3 - "$BUNDLE/hf/tiktoken" "$HF_CACHE_DIR/tiktoken" <<'PYEOF'
import hashlib
import os
import shutil
import sys

src, dst = sys.argv[1], sys.argv[2]
errors = []
files = []  # (absolute src path, relative path)
for dirpath, dirnames, filenames in os.walk(src):
    rel_dir = os.path.relpath(dirpath, src)
    for dname in dirnames:
        if os.path.islink(os.path.join(dirpath, dname)):
            rel = os.path.join(rel_dir, dname) if rel_dir != "." else dname
            errors.append(f"tiktoken bundle contains a symlinked dir: {rel}")
    for name in filenames:
        path = os.path.join(dirpath, name)
        rel = os.path.join(rel_dir, name) if rel_dir != "." else name
        if os.path.islink(path):
            errors.append(f"tiktoken bundle contains a symlink: {rel}")
            continue
        files.append((path, rel))


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.digest()


# Decide everything before touching the destination: a refused overwrite or
# a planted symlink must not leave a half-copied tiktoken dir behind.
to_copy, to_skip = [], []
if not errors:
    for path, rel in files:
        target = os.path.join(dst, rel)
        if os.path.lexists(target):
            if os.path.islink(target):
                errors.append(f"refusing to overwrite a symlink: {target}")
            elif os.path.isfile(target) and \
                    sha256(target) == sha256(path):
                to_skip.append(target)
            else:
                errors.append(
                    f"refusing to overwrite a differing tiktoken file: "
                    f"{target}")
        else:
            to_copy.append((path, target))

if errors:
    for e in errors[:10]:
        print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
for path, target in to_copy:
    os.makedirs(os.path.dirname(target), exist_ok=True)
    shutil.copy2(path, target)
print(f"  tiktoken: {len(to_copy)} copied, {len(to_skip)} identical skipped")
PYEOF
    fi
  fi

  # Every MANIFEST model must resolve at the destination.
  echo "+ check refs/main + snapshot dir for every MANIFEST model in $HF_CACHE_DIR"
  if [[ $DRY_RUN -eq 0 ]]; then
    python3 - "$BUNDLE/MANIFEST.json" "$HF_CACHE_DIR" <<'PYEOF'
import json
import os
import sys

man = json.load(open(sys.argv[1], encoding="utf-8"))
cache = sys.argv[2]
bad = []
for m in man.get("models") or []:
    mdir = "models--" + m.get("model", "").replace("/", "--")
    base = os.path.join(cache, "hub", mdir)
    refs = os.path.join(base, "refs", "main")
    if not os.path.isfile(refs):
        bad.append(f"{mdir}: refs/main missing at the destination")
        continue
    with open(refs, encoding="utf-8") as f:
        rev = f.read().strip()
    if rev and not os.path.isdir(os.path.join(base, "snapshots", rev)):
        bad.append(f"{mdir}: snapshot dir {rev} missing at the destination")
if bad:
    for b in bad:
        print(f"ERROR: {b}", file=sys.stderr)
    sys.exit(1)
print(f"all {len(man.get('models') or [])} model cache(s) resolve offline")
PYEOF
  fi
}

# ------------------------------------------------------------------ run ----

if [[ $DO_K3S -eq 1 ]]; then
  do_install_k3s
fi
if [[ $DO_IMAGES -eq 1 ]]; then
  do_load_images
fi
if [[ $DO_MODELS -eq 1 ]]; then
  do_load_models
fi

note "done. Next (stage B/C — run them yourself, with your approval):"
echo "  cd \"$BUNDLE/spark\""
echo "  OFFLINE=1 ./install-spark-k8s.sh --dry-run"
echo "  OFFLINE=1 ./install-spark-k8s.sh --device-plugin"
echo "  OFFLINE=1 ./install-spark-k8s.sh --apply   # or --migrate-from-docker (stage C, service interruption)"
