#!/usr/bin/env python3
"""Tests for the offline (air-gapped) bundle: pack-spark-offline.sh builds it
on a connected arm64 host, install-spark-offline.sh consumes it on the DGX
with ZERO network calls. External commands are POSIX-sh stubs on a private
PATH (curl, docker, hf, huggingface-cli, sudo, k3s, uname, df) that append
their argv to a log; only the interpreter dir plus /usr/bin:/bin survive from
the real PATH, so a host k3s/hf/docker binary can never leak into a test.

Also covers the controller-side offline switch: the VLLM_OFFLINE config key
and the env it injects into the vLLM container."""

import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PARENT = os.path.dirname(HERE)
sys.path.insert(0, PARENT)

PACK_SCRIPT = os.path.join(PARENT, "pack-spark-offline.sh")
INSTALL_SCRIPT = os.path.join(PARENT, "install-spark-offline.sh")
K8S_SCRIPT = os.path.join(PARENT, "install-spark-k8s.sh")
PROFILES_PATH = os.path.join(PARENT, "profiles.json")
DEVPLUG_YAML = os.path.join(PARENT, "k8s", "device-plugin",
                            "nvidia-device-plugin.yaml")

K3S_VERSION = "v1.36.6+k3s1"
VLLM_REF = "nvcr.io/nvidia/vllm:26.02-py3"
QWEN_MODEL = "Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8"
NEXT_MODEL = "Qwen/Qwen3-Next-80B-A3B-Instruct-FP8"
GPT_OSS_MODEL = "openai/gpt-oss-120b"
HF_TOKEN_SENTINEL = "hf_token_sentinel_never_leak_987654"

K3S_BIN_BYTES = b"k3s-bin-bytes"
AIRGAP_BYTES = b"airgap-bytes"

EXCLUDE_GLOBS = ["original/*", "metal/*"]

TOKEN_LINE = "SWITCH_TOKEN=" + "t" * 40 + "\n"


# ---------------------------------------------------------------- stubs ----
# Plain (non-raw) triple-quoted strings: "\\n" below becomes a literal
# backslash-n inside the shell script, which is what printf wants.

CURL_STUB = """#!/bin/sh
printf '%s\\n' "curl $*" >> "$STUB_LOG"
out=""
url=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then out="$a"; fi
  url="$a"
  prev="$a"
done
case "$url" in
  *k3s-airgap-images*) printf 'airgap-bytes' > "$out" ;;
  *sha256sum-arm64.txt*)
    printf '%s  k3s-arm64\\n%s  k3s-airgap-images-arm64.tar.zst\\n' \\
      '@@K3SSHA@@' '@@AIRSHA@@' > "$out" ;;
  *k3s-arm64*)
    if [ -n "${STUB_CORRUPT_K3S:-}" ]; then printf 'corrupted!' > "$out"
    else printf 'k3s-bin-bytes' > "$out"; fi ;;
  *install.sh) printf '#!/bin/sh\\nexit 0\\n' > "$out" ;;
  *tiktoken*) printf 'encoding-bytes' > "$out" ;;
  *) printf 'x' > "$out" ;;
esac
exit 0
""".replace("@@K3SSHA@@", hashlib.sha256(K3S_BIN_BYTES).hexdigest()) \
   .replace("@@AIRSHA@@", hashlib.sha256(AIRGAP_BYTES).hexdigest())

DOCKER_STUB = """#!/bin/sh
printf '%s\\n' "docker $*" >> "$STUB_LOG"
case "$*" in
  *"{{.Architecture}}"*) echo "${STUB_DOCKER_ARCH:-arm64}"; exit 0 ;;
  *"{{.Id}}"*) echo "sha256:fakeimageid000000"; exit 0 ;;
  "run --rm"*)
    # the offline-download fallback: create the HF cache layout inside the
    # bind-mounted host dir (the mount IS the cache root, HF_HUB_CACHE=/hf).
    # argv ends with: ... -c <code> <model> <exclusion-csv> — the model id is
    # the second-to-last argument.
    host=""
    model=""
    prev=""
    prevprev=""
    for a in "$@"; do
      if [ "$prev" = "-v" ]; then host="${a%%:*}"; fi
      prevprev="$prev"
      prev="$a"
    done
    model="$prevprev"
    mdir="$host/models--${model%%/*}--${model##*/}"
    rev="feedface0000"
    mkdir -p "$mdir/blobs" "$mdir/snapshots/$rev" "$mdir/refs"
    printf '%s' "$rev" > "$mdir/refs/main"
    printf 'downloaded-blob' > "$mdir/blobs/blob0"
    ln -sf ../../blobs/blob0 "$mdir/snapshots/$rev/config.json"
    exit 0 ;;
  *"save -o"*)
    out=""
    prev=""
    for a in "$@"; do
      if [ "$prev" = "-o" ]; then out="$a"; fi
      prev="$a"
    done
    printf 'docker-image-tar' > "$out"
    exit 0 ;;
esac
# image inspect <ref> without --format: presence probe
exit "${STUB_DOCKER_PRESENT_RC:-0}"
"""

# One body serves both the `hf` and `huggingface-cli` stubs (@@NAME@@).
HF_STUB = """#!/bin/sh
printf '%s\\n' "@@NAME@@ $*" >> "$STUB_LOG"
model=""
cachedir=""
prev=""
for a in "$@"; do
  if [ "$prev" = "download" ] && [ -z "$model" ]; then model="$a"; fi
  if [ "$prev" = "--cache-dir" ]; then cachedir="$a"; fi
  prev="$a"
done
mdir="$cachedir/models--${model%%/*}--${model##*/}"
rev="feedface0000"
mkdir -p "$mdir/blobs" "$mdir/snapshots/$rev" "$mdir/refs"
printf '%s' "$rev" > "$mdir/refs/main"
printf 'downloaded-blob' > "$mdir/blobs/blob0"
ln -sf ../../blobs/blob0 "$mdir/snapshots/$rev/config.json"
exit 0
"""

SUDO_STUB = """#!/bin/sh
# $* here EXCLUDES the "sudo" word itself (the stub's own name is sudo).
case "$*" in
  "tee "*)
    stdin_data="$(cat)"
    printf '%s\\n' "sudo $* STDIN[$stdin_data]" >> "$STUB_LOG"
    ;;
  *) printf '%s\\n' "sudo $*" >> "$STUB_LOG" ;;
esac
case "$*" in
  "-n true") exit "${STUB_SUDO_RC:-0}" ;;
  "cat /etc/rancher/k3s/k3s.yaml")
    printf 'apiVersion: v1\\nkind: Config\\n'
    exit 0 ;;
  *"test -s /etc/rancher/k3s/k3s.yaml")
    exit "${STUB_SUDO_K3SYAML_RC:-0}" ;;
  *"ctr version") exit "${STUB_SUDO_RC:-0}" ;;
  *"images ls -q"*) printf '%s\\n' "${STUB_CTR_REFS:-}"; exit 0 ;;
esac
exit 0
"""

# Real k3s prints 2 lines; the version token is on line 1, field 3.
K3S_STUB = """#!/bin/sh
printf '%s\\n' "k3s $*" >> "$STUB_LOG"
echo "k3s version ${STUB_K3S_INSTALLED:-v1.36.6+k3s1} (abc1234)"
echo "go version go1.36.0"
exit 0
"""

UNAME_STUB = """#!/bin/sh
printf '%s\\n' "uname $*" >> "$STUB_LOG"
echo "${STUB_UNAME_M:-aarch64}"
exit 0
"""

DF_STUB = """#!/bin/sh
printf '%s\\n' "df $*" >> "$STUB_LOG"
echo 'Filesystem 1024-blocks Used Available Capacity Mounted'
echo "/dev/fake 9999999999 1 ${STUB_DF_AVAIL_KB:-9999999999} 1% /"
exit 0
"""

RUNTIME_STUB = """#!/bin/sh
exit 0
"""


# --------------------------------------------------------------- helpers ----

def make_hf_cache(root, model=QWEN_MODEL, rev="deadbeef0000",
                  blob=b"qwen-weights", with_original=False,
                  with_incomplete=False, with_second_rev=False):
    """A minimal HF hub cache entry with the REAL layout: snapshot files are
    relative symlinks into ../../blobs/. Optional junk that a real cache
    accumulates: a duplicate original/ weight tree, a *.incomplete blob and
    a second (pre-release) revision."""
    mdir = "models--" + model.replace("/", "--")
    base = os.path.join(root, "hub", mdir)

    def relink(link_text, path):
        if os.path.lexists(path):
            os.remove(path)
        os.symlink(link_text, path)

    os.makedirs(os.path.join(base, "blobs"), exist_ok=True)
    os.makedirs(os.path.join(base, "snapshots", rev), exist_ok=True)
    os.makedirs(os.path.join(base, "refs"), exist_ok=True)
    with open(os.path.join(base, "blobs", "blob1"), "wb") as f:
        f.write(blob)
    with open(os.path.join(base, "refs", "main"), "w", encoding="utf-8") as f:
        f.write(rev)
    relink("../../blobs/blob1",
           os.path.join(base, "snapshots", rev, "config.json"))
    if with_original:
        with open(os.path.join(base, "blobs", "blob2"), "wb") as f:
            f.write(b"original-weights")
        os.makedirs(os.path.join(base, "snapshots", rev, "original"),
                    exist_ok=True)
        relink("../../../blobs/blob2",
               os.path.join(base, "snapshots", rev, "original",
                            "consolidated.safetensors"))
    if with_second_rev:
        rev2 = "cafebabedead"
        with open(os.path.join(base, "blobs", "blob3"), "wb") as f:
            f.write(b"prerelease-weights")
        os.makedirs(os.path.join(base, "snapshots", rev2), exist_ok=True)
        relink("../../blobs/blob3",
               os.path.join(base, "snapshots", rev2, "config.json"))
        with open(os.path.join(base, "refs", "prerelease"), "w",
                  encoding="utf-8") as f:
            f.write(rev2)
    if with_incomplete:
        with open(os.path.join(base, "blobs", "abc123.incomplete"),
                  "wb") as f:
            f.write(b"half-downloaded")
    return base


def bundle_regular_files(root):
    """Every regular (non-symlink) file under root, relative paths."""
    out = set()
    for dp, _, names in os.walk(root):
        for n in names:
            p = os.path.join(dp, n)
            if os.path.islink(p):
                continue
            out.add(os.path.relpath(p, root))
    return out


class OfflineScriptTestCase(unittest.TestCase):
    """Shared stub PATH + argv-log plumbing for both scripts."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.stubdir = os.path.join(self.tmp, "bin")
        self.home = os.path.join(self.tmp, "home")
        tmpdir = os.path.join(self.tmp, "tmp")
        os.makedirs(self.stubdir)
        os.makedirs(self.home)
        os.makedirs(tmpdir)
        self.log = os.path.join(self.tmp, "calls.log")

        env = dict(os.environ)
        env["PATH"] = (self.stubdir + os.pathsep
                       + os.path.dirname(os.path.abspath(sys.executable))
                       + os.pathsep + "/usr/bin:/bin")
        env["HOME"] = self.home
        env["TMPDIR"] = tmpdir
        env["STUB_LOG"] = self.log
        for var in ("HF_TOKEN", "OFFLINE", "STUB_CORRUPT_K3S",
                    "STUB_DOCKER_ARCH", "STUB_UNAME_M", "STUB_K3S_INSTALLED",
                    "K3S_KUBECONFIG_WAIT_SECONDS", "STUB_SUDO_K3SYAML_RC"):
            env.pop(var, None)
        self.env = env

    def install_stub(self, name, body):
        path = os.path.join(self.stubdir, name)
        with open(path, "w", encoding="utf-8") as f:
            f.write(body)
        os.chmod(path, 0o755)

    def remove_stub(self, name):
        os.remove(os.path.join(self.stubdir, name))

    def run_script(self, script, *args, **env_over):
        if os.path.exists(self.log):
            os.remove(self.log)
        env = dict(self.env)
        env.update({k: str(v) for k, v in env_over.items()})
        return subprocess.run(["bash", script, *args], env=env,
                              capture_output=True, text=True, timeout=120,
                              cwd=PARENT)

    def calls(self):
        if not os.path.exists(self.log):
            return []
        with open(self.log, encoding="utf-8") as f:
            return [line.rstrip("\n") for line in f if line.strip()]

    def log_text(self):
        if not os.path.exists(self.log):
            return ""
        with open(self.log, encoding="utf-8") as f:
            return f.read()

    def lines_with(self, fragment):
        return [line for line in self.calls() if fragment in line]


# ------------------------------------------------------------ pack tests ----


class PackOfflineTests(OfflineScriptTestCase):
    def setUp(self):
        super().setUp()
        self.install_stub("curl", CURL_STUB)
        self.install_stub("docker", DOCKER_STUB)
        self.install_stub("hf", HF_STUB.replace("@@NAME@@", "hf"))
        self.install_stub("huggingface-cli",
                          HF_STUB.replace("@@NAME@@", "huggingface-cli"))
        self.hf_cache = os.path.join(self.tmp, "hf-cache")
        self.qwen_dir = make_hf_cache(self.hf_cache)
        self.out = os.path.join(self.tmp, "bundle")

    def run_pack(self, *args, **env_over):
        return self.run_script(PACK_SCRIPT, "--out", self.out,
                               "--hf-cache", self.hf_cache, *args, **env_over)

    def test_full_pack_local_cache_manifest_and_sums(self):
        proc = self.run_pack("--profiles", "qwen3-coder")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

        # local cache copied, symlinks PRESERVED (never dereferenced)
        snapshot = os.path.join(
            self.out, "hf", "hub", "models--Qwen--Qwen3-Coder-30B-A3B-"
            "Instruct-FP8", "snapshots", "deadbeef0000", "config.json")
        self.assertTrue(os.path.islink(snapshot), snapshot)
        expected_blob = os.path.join(os.path.dirname(os.path.dirname(
            os.path.dirname(snapshot))), "blobs", "blob1")
        # realpath on BOTH sides: /tmp vs /private/tmp on macOS
        self.assertEqual(os.path.realpath(snapshot),
                         os.path.realpath(expected_blob))
        self.assertEqual(self.lines_with("hf download"), [])   # local cache hit

        # k3s component downloaded and verified against the sums file
        for f in ("k3s-arm64", "k3s-airgap-images-arm64.tar.zst",
                  "install.sh", "sha256sum-arm64.txt"):
            self.assertTrue(os.path.isfile(os.path.join(self.out, "k3s", f)), f)

        # images: both refs saved as tars, ids recorded in IMAGE_IDS
        for f in ("vllm.tar", "k8s-device-plugin.tar", "IMAGE_IDS"):
            self.assertTrue(os.path.isfile(os.path.join(self.out, "images", f)),
                            f)
        with open(os.path.join(self.out, "images", "IMAGE_IDS"),
                  encoding="utf-8") as f:
            id_lines = [line.rstrip("\n") for line in f if line.strip()]
        self.assertEqual(id_lines, [
            f"vllm.tar\t{VLLM_REF}\tsha256:fakeimageid000000",
            "k8s-device-plugin.tar\tnvcr.io/nvidia/k8s-device-plugin:"
            "v0.17.4\tsha256:fakeimageid000000"])
        with open(os.path.join(self.out, "MANIFEST.json"),
                  encoding="utf-8") as f:
            man = json.load(f)
        self.assertEqual(man["format"], 1)
        self.assertEqual(man["arch"], "arm64")
        self.assertEqual(man["k3s_version"], K3S_VERSION)
        self.assertEqual(
            [i["ref"] for i in man["images"]],
            [VLLM_REF, "nvcr.io/nvidia/k8s-device-plugin:v0.17.4"])
        self.assertEqual([i["file"] for i in man["images"]],
                         ["images/vllm.tar", "images/k8s-device-plugin.tar"])
        self.assertEqual(man["images"][0]["image_id"],
                         "sha256:fakeimageid000000")
        self.assertEqual(man["models"], [{"profile": "qwen3-coder",
                                          "model": QWEN_MODEL,
                                          "revision": "deadbeef0000",
                                          "exclude": EXCLUDE_GLOBS}])
        self.assertFalse(man["tiktoken"])   # no gpt-oss profile packed
        self.assertRegex(man["created"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")

        # spark payload: exactly the shipped files, no tests/, no secrets
        spark = os.path.join(self.out, "spark")
        for f in ("spark_switch.py", "spark_common.py",
                  "spark_backend_docker.py", "spark_backend_kube.py",
                  "profiles.json", "env.example", "README.md",
                  "install-spark-switch.sh", "install-spark-k8s.sh",
                  "install-spark-offline.sh"):
            self.assertTrue(os.path.isfile(os.path.join(spark, f)), f)
        self.assertTrue(os.path.isdir(os.path.join(spark, "k8s")))
        self.assertFalse(os.path.exists(os.path.join(spark, "tests")))
        self.assertFalse(os.path.exists(os.path.join(spark, "env")))
        self.assertEqual(os.listdir(os.path.join(spark, "k8s", "overlays",
                                                "spark")).count(
            "offline-env-patch.yaml"), 1)

        # SHA256SUMS: every regular file except itself and the dot-markers,
        # sorted, correct — dot markers and .partial paths are NEVER listed
        sums_path = os.path.join(self.out, "SHA256SUMS")
        with open(sums_path, encoding="utf-8") as f:
            sum_lines = [line.rstrip("\n") for line in f if line.strip()]
        entries = {}
        for line in sum_lines:
            digest, rel = line.split("  ", 1)
            entries[rel] = digest
        listed = bundle_regular_files(self.out)
        listed.discard("SHA256SUMS")   # the list never hashes itself
        # the resume markers DO exist in the bundle, unlisted by design
        markers = {p for p in listed if os.path.basename(p).startswith(".")}
        self.assertTrue(markers, "expected .done-* markers in the bundle")
        for rel in entries:
            self.assertFalse(os.path.basename(rel).startswith("."),
                             f"marker hashed: {rel}")
            self.assertNotIn(".partial", rel)
        listed -= markers
        self.assertEqual(set(entries), listed)
        for rel, digest in entries.items():
            with open(os.path.join(self.out, rel), "rb") as f:
                self.assertEqual(digest, hashlib.sha256(f.read()).hexdigest(),
                                 rel)
        paths = [line.split("  ", 1)[1] for line in sum_lines]
        self.assertEqual(paths, sorted(paths))

        # no staging leftovers anywhere in the finished bundle
        for dp, dns, _ in os.walk(self.out):
            for d in dns:
                self.assertNotIn(".partial", d)

        # size summary per component was printed
        for comp in ("k3s", "images", "hf", "spark"):
            self.assertIn(comp, proc.stdout)

    def test_dry_run_creates_nothing(self):
        proc = self.run_pack("--dry-run", "--profiles", "qwen3-coder")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertFalse(os.path.exists(self.out))   # not even the dir
        echoed = [line for line in proc.stdout.splitlines()
                  if line.startswith("+ ")]
        self.assertTrue(any("curl -fL --retry 3 -o" in e for e in echoed))
        self.assertTrue(any("docker save -o" in e for e in echoed))
        self.assertTrue(any("python3 copy models--" in e for e in echoed))
        self.assertEqual(self.lines_with("curl "), [])
        self.assertEqual(self.lines_with("docker "), [])

    def test_refuses_non_empty_out_without_resume(self):
        os.makedirs(self.out)
        with open(os.path.join(self.out, "stray.txt"), "w",
                  encoding="utf-8") as f:
            f.write("x")
        proc = self.run_pack("--profiles", "qwen3-coder")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("--resume", proc.stderr)
        self.assertEqual(self.lines_with("curl "), [])

        # with --resume the same directory is accepted
        proc = self.run_pack("--resume", "--profiles", "qwen3-coder")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertTrue(os.path.isdir(os.path.join(self.out, "k3s")))

    def test_resume_skips_done_components(self):
        proc = self.run_pack("--profiles", "qwen3-coder")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

        proc = self.run_pack("--resume", "--profiles", "qwen3-coder")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        for comp in ("k3s", "images", "models", "spark"):
            self.assertIn(f"{comp} already packed; skipping", proc.stdout)
        # no component work ran again — image ids come from IMAGE_IDS, so not
        # even a read-only docker re-inspect happens on --resume
        self.assertEqual(self.lines_with("curl "), [])
        self.assertEqual(self.lines_with("docker "), [])
        self.assertEqual(self.lines_with("hf download"), [])

    def test_model_excludes_duplicate_weight_trees(self):
        # a realistic cache: original/ duplicate weights, a *.incomplete blob
        # and a second (pre-release) revision — none of it may reach the
        # bundle, and every download tool must be told the same globs.
        make_hf_cache(self.hf_cache, with_original=True, with_incomplete=True,
                      with_second_rev=True)
        proc = self.run_pack("--profiles", "qwen3-coder", "--no-k3s",
                             "--no-images")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        base = os.path.join(self.out, "hf", "hub",
                            "models--" + QWEN_MODEL.replace("/", "--"))
        snap = os.path.join(base, "snapshots", "deadbeef0000")
        self.assertTrue(os.path.islink(os.path.join(snap, "config.json")))
        self.assertFalse(os.path.exists(os.path.join(snap, "original")))
        self.assertFalse(os.path.exists(os.path.join(base, "snapshots",
                                                     "cafebabedead")))
        self.assertEqual(sorted(os.listdir(os.path.join(base, "blobs"))),
                         ["blob1"])
        self.assertEqual(sorted(os.listdir(os.path.join(base, "refs"))),
                         ["main"])

        # --include-all-files keeps the duplicate tree and records no excludes
        out_all = os.path.join(self.tmp, "bundle-all")
        proc = self.run_pack("--out", out_all, "--profiles", "qwen3-coder",
                             "--no-k3s", "--no-images", "--include-all-files")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        base_all = os.path.join(out_all, "hf", "hub",
                                "models--" + QWEN_MODEL.replace("/", "--"))
        orig = os.path.join(base_all, "snapshots", "deadbeef0000", "original",
                            "consolidated.safetensors")
        self.assertTrue(os.path.islink(orig), orig)   # kept as a symlink
        self.assertTrue(os.path.isfile(os.path.join(base_all, "blobs",
                                                    "blob2")))
        with open(os.path.join(out_all, "MANIFEST.json"),
                  encoding="utf-8") as f:
            man = json.load(f)
        self.assertEqual(man["models"][0]["exclude"], [])

    def test_missing_model_downloaded_with_cache_dir(self):
        # qwen3-next-80b is NOT in the fake cache -> the hf CLI is used with
        # --cache-dir pointing into the bundle staging dir, exclusions passed
        proc = self.run_pack("--profiles", "qwen3-next-80b",
                             "--no-k3s", "--no-images")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        downloads = self.lines_with("hf download")
        self.assertEqual(len(downloads), 1, downloads)
        self.assertIn(NEXT_MODEL, downloads[0])
        self.assertIn("--cache-dir", downloads[0])
        self.assertIn("hf.partial/hub", downloads[0])
        for glob in EXCLUDE_GLOBS:
            self.assertIn(f"--exclude {glob}", downloads[0])
        # the downloaded cache entry (with its symlink) landed in the bundle
        mdir = "models--" + NEXT_MODEL.replace("/", "--")
        snap = os.path.join(self.out, "hf", "hub", mdir, "snapshots",
                            "feedface0000", "config.json")
        self.assertTrue(os.path.islink(snap), snap)
        with open(os.path.join(self.out, "MANIFEST.json"),
                  encoding="utf-8") as f:
            man = json.load(f)
        self.assertEqual(man["models"][0]["revision"], "feedface0000")

    def test_huggingface_cli_fallback_when_no_hf_binary(self):
        self.remove_stub("hf")
        proc = self.run_pack("--profiles", "qwen3-next-80b",
                             "--no-k3s", "--no-images")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(self.lines_with("hf download"), [])
        cli = self.lines_with("huggingface-cli download")
        self.assertEqual(len(cli), 1)
        for glob in EXCLUDE_GLOBS:
            self.assertIn(f"--exclude {glob}", cli[0])

    def test_docker_fallback_when_no_hf_cli_at_all(self):
        self.remove_stub("hf")
        self.remove_stub("huggingface-cli")
        proc = self.run_pack("--profiles", "qwen3-next-80b",
                             "--no-k3s", "--no-images")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        runs = self.lines_with("docker run --rm")
        self.assertEqual(len(runs), 1, runs)
        self.assertIn("--user", runs[0])   # files owned by the invoking user
        self.assertIn("HF_HUB_CACHE=/hf", runs[0])
        self.assertIn(VLLM_REF, runs[0])
        # exclusions travel as an argv element (comma list for python) — the
        # argv contains a newline, so assert against the whole log
        self.assertIn(",".join(EXCLUDE_GLOBS), self.log_text())
        # the model id travels as the LAST argv element (the embedded python
        # code contains a newline, so check the raw log, not split lines)
        self.assertIn("snapshot_download(sys.argv[1]) " + NEXT_MODEL,
                      self.log_text())
        # ...never interpolated into the python code itself
        self.assertNotIn("snapshot_download(" + NEXT_MODEL, self.log_text())

    def test_hf_token_only_passed_by_name_to_docker(self):
        self.remove_stub("hf")
        self.remove_stub("huggingface-cli")
        proc = self.run_pack("--profiles", "qwen3-next-80b",
                             "--no-k3s", "--no-images",
                             HF_TOKEN=HF_TOKEN_SENTINEL)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertNotIn(HF_TOKEN_SENTINEL, proc.stdout + proc.stderr)
        self.assertNotIn(HF_TOKEN_SENTINEL, self.log_text())
        runs = self.lines_with("docker run --rm")
        self.assertEqual(len(runs), 1, runs)
        # -e HF_TOKEN passes the NAME only; the value is inherited from the
        # environment and must never appear as HF_TOKEN=<value>
        self.assertIn(" -e HF_TOKEN ", runs[0])
        self.assertNotIn("HF_TOKEN=", self.log_text())

        # without HF_TOKEN in the environment the flag is not passed at all
        proc = self.run_pack("--out", os.path.join(self.tmp, "b2"),
                             "--profiles", "qwen3-next-80b",
                             "--no-k3s", "--no-images")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertNotIn("HF_TOKEN", self.log_text())

    def test_local_cache_unusable_falls_back_to_download(self):
        # dangling symlink inside the snapshot -> the local entry is refused
        # (never packed partially) and the model downloads instead
        base = make_hf_cache(self.hf_cache)
        snap = os.path.join(base, "snapshots", "deadbeef0000")
        os.remove(os.path.join(snap, "config.json"))
        os.symlink("../../blobs/no-such-blob", os.path.join(snap,
                                                            "config.json"))
        proc = self.run_pack("--profiles", "qwen3-coder", "--no-k3s",
                             "--no-images")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("local cache entry unusable", proc.stdout)
        downloads = self.lines_with("hf download")
        self.assertEqual(len(downloads), 1, downloads)
        self.assertIn(QWEN_MODEL, downloads[0])
        # the bundle carries the downloaded (valid) entry, not the broken one
        bundle_snap = os.path.join(
            self.out, "hf", "hub", "models--" + QWEN_MODEL.replace("/", "--"),
            "snapshots", "feedface0000", "config.json")
        self.assertTrue(os.path.islink(bundle_snap), bundle_snap)

        # a symlink escaping the model's blobs/ is equally unusable
        out2 = os.path.join(self.tmp, "bundle2")
        base2 = make_hf_cache(self.hf_cache)   # same cache, rebuild entry
        snap2 = os.path.join(base2, "snapshots", "deadbeef0000")
        os.remove(os.path.join(snap2, "config.json"))
        os.symlink("../../../../../etc/passwd",
                   os.path.join(snap2, "config.json"))
        proc = self.run_pack("--out", out2, "--profiles", "qwen3-coder",
                             "--no-k3s", "--no-images")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("local cache entry unusable", proc.stdout)
        self.assertEqual(len(self.lines_with("hf download")), 1)

    def test_model_resume_and_tiktoken_survival(self):
        # model A (gpt-oss) is complete with its marker; model B is a partial
        # staging dir -> A is NOT re-downloaded, B completes, and hf/tiktoken
        # (from an earlier tiktoken component run) survives untouched.
        cache_empty = os.path.join(self.tmp, "hf-empty")
        os.makedirs(cache_empty)
        out = self.out
        os.makedirs(os.path.join(out, "hf", "tiktoken"))
        for enc, data in (("o200k_base.tiktoken", b"o200k-keep"),
                          ("cl100k_base.tiktoken", b"cl100k-keep")):
            with open(os.path.join(out, "hf", "tiktoken", enc), "wb") as f:
                f.write(data)
        open(os.path.join(out, ".done-tiktoken"), "w").close()
        # model A complete in the staging hub + its marker
        a_mdir = "models--" + GPT_OSS_MODEL.replace("/", "--")
        a_staged = os.path.join(out, "hf.partial", "hub", a_mdir)
        os.makedirs(os.path.join(a_staged, "refs"))
        os.makedirs(os.path.join(a_staged, "snapshots", "deadbeef0000"))
        os.makedirs(os.path.join(a_staged, "blobs"))
        with open(os.path.join(a_staged, "refs", "main"), "w",
                  encoding="utf-8") as f:
            f.write("deadbeef0000")
        with open(os.path.join(a_staged, "blobs", "blobA"), "wb") as f:
            f.write(b"gpt-oss-weights")
        os.symlink("../../blobs/blobA", os.path.join(a_staged, "snapshots",
                                                     "deadbeef0000",
                                                     "config.json"))
        open(os.path.join(out, ".done-model-gpt-oss-120b"), "w").close()
        # model B: a half-finished staging dir and NO marker
        b_mdir = "models--" + NEXT_MODEL.replace("/", "--")
        os.makedirs(os.path.join(out, "hf.partial", "hub",
                                 b_mdir + ".partial"))

        proc = self.run_script(PACK_SCRIPT, "--out", out, "--hf-cache",
                               cache_empty, "--resume", "--profiles",
                               "gpt-oss-120b,qwen3-next-80b", "--no-k3s",
                               "--no-images")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("gpt-oss-120b: model already packed; skipping",
                      proc.stdout)
        downloads = self.lines_with("hf download")
        self.assertEqual(len(downloads), 1, downloads)   # B only
        self.assertIn(NEXT_MODEL, downloads[0])
        self.assertNotIn(GPT_OSS_MODEL, self.log_text())
        # both models finished into hf/hub; the marker for B now exists
        for mdir in (a_mdir, b_mdir):
            self.assertTrue(os.path.isdir(os.path.join(out, "hf", "hub",
                                                       mdir)), mdir)
        self.assertTrue(os.path.isfile(
            os.path.join(out, ".done-model-qwen3-next-80b")))
        # tiktoken was never re-fetched and its bytes are intact
        self.assertEqual(self.lines_with("curl "), [])
        with open(os.path.join(out, "hf", "tiktoken", "o200k_base.tiktoken"),
                  "rb") as f:
            self.assertEqual(f.read(), b"o200k-keep")
        # the finished bundle has no staging leftovers
        for dp, dns, _ in os.walk(out):
            for d in dns:
                self.assertNotIn(".partial", d)

    def test_finalize_refuses_bundle_with_leftover_partial(self):
        proc = self.run_pack("--profiles", "qwen3-coder")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        # plant an unfinished model staging dir and re-run --resume: the
        # finalize step must refuse to rewrite MANIFEST/SHA256SUMS
        os.makedirs(os.path.join(self.out, "hf.partial", "hub",
                                 "models--leftover.partial"))
        proc = self.run_pack("--resume", "--profiles", "qwen3-coder")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("refusing to write MANIFEST/SHA256SUMS", proc.stderr)
        self.assertIn("models--leftover.partial", proc.stderr)

    def test_image_ids_survive_resume_without_docker(self):
        proc = self.run_pack("--profiles", "qwen3-coder")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        with open(os.path.join(self.out, "MANIFEST.json"),
                  encoding="utf-8") as f:
            before = json.load(f)
        # the local docker image was pruned after packing: --resume must
        # still produce a complete MANIFEST from images/IMAGE_IDS
        self.remove_stub("docker")
        proc = self.run_pack("--resume", "--profiles", "qwen3-coder")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(self.lines_with("docker "), [])
        with open(os.path.join(self.out, "MANIFEST.json"),
                  encoding="utf-8") as f:
            after = json.load(f)
        self.assertEqual([i["image_id"] for i in after["images"]],
                         [i["image_id"] for i in before["images"]])
        self.assertTrue(all(i["image_id"] for i in after["images"]))

    def test_tiktoken_only_for_gpt_oss_profiles(self):
        proc = self.run_pack("--profiles", "qwen3-coder",
                             "--no-k3s", "--no-images")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(self.lines_with("curl "), [])
        self.assertFalse(os.path.exists(os.path.join(self.out, "hf",
                                                     "tiktoken")))

        # a separate out dir: run_pack's later --out wins over the default
        out_oss = os.path.join(self.tmp, "bundle-oss")
        proc = self.run_pack("--out", out_oss, "--profiles", "gpt-oss-120b",
                             "--no-k3s", "--no-images")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        tok_urls = [line for line in self.lines_with("curl ")
                    if "tiktoken" in line]
        self.assertEqual(len(tok_urls), 2)
        for enc in ("o200k_base.tiktoken", "cl100k_base.tiktoken"):
            self.assertTrue(os.path.isfile(
                os.path.join(out_oss, "hf", "tiktoken", enc)), enc)
        with open(os.path.join(out_oss, "MANIFEST.json"),
                  encoding="utf-8") as f:
            man = json.load(f)
        self.assertTrue(man["tiktoken"])
        # gpt-oss model itself must be in the bundle's hub too
        self.assertTrue(os.path.isdir(os.path.join(
            out_oss, "hf", "hub",
            "models--openai--gpt-oss-120b", "refs")))

    def test_k3s_sha_mismatch_fails(self):
        proc = self.run_pack("--profiles", "qwen3-coder", "--no-images",
                             STUB_CORRUPT_K3S=1)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("sha256 mismatch", proc.stderr)
        self.assertIn("k3s-arm64", proc.stderr)
        # the failed component never became final, no marker was written
        self.assertFalse(os.path.exists(os.path.join(self.out, "k3s")))
        self.assertFalse(os.path.exists(os.path.join(self.out, ".done-k3s")))
        self.assertFalse(os.path.exists(os.path.join(self.out, "MANIFEST.json")))

    def test_non_arm64_image_fails(self):
        proc = self.run_pack("--profiles", "qwen3-coder", "--no-k3s",
                             STUB_DOCKER_ARCH="amd64")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("expected arm64", proc.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.out, "images")))

    def test_device_plugin_image_read_from_manifest_yaml(self):
        with open(DEVPLUG_YAML, encoding="utf-8") as f:
            yaml_text = f.read()
        refs = [line.split("image:", 1)[1].strip()
                for line in yaml_text.splitlines()
                if line.strip().startswith("- image:")]
        self.assertEqual(len(refs), 1)
        ref = refs[0].strip('"')

        proc = self.run_pack("--profiles", "qwen3-coder", "--no-k3s",
                             "--no-models")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        saves = self.lines_with("docker save -o")
        self.assertTrue(any(ref in line and "k8s-device-plugin.tar" in line
                            for line in saves), saves)
        with open(os.path.join(self.out, "MANIFEST.json"),
                  encoding="utf-8") as f:
            man = json.load(f)
        self.assertEqual(man["images"][1]["ref"], ref)

    def test_plus_in_k3s_version_is_url_encoded(self):
        proc = self.run_pack("--profiles", "qwen3-coder", "--no-images",
                             "--no-models")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        k3s_curls = [line for line in self.lines_with("curl ")
                     if "k3s" in line]
        self.assertTrue(k3s_curls)
        for line in k3s_curls:
            self.assertIn("v1.36.6%2Bk3s1", line)
            self.assertNotIn("v1.36.6+k3s1", line)

    def test_k3s_version_below_v1_30_rejected(self):
        proc = self.run_pack("--k3s-version", "v1.29.1+k3s1")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("v1.30+", proc.stderr)
        self.assertEqual(self.lines_with("curl "), [])

    def test_unknown_profile_rejected(self):
        proc = self.run_pack("--profiles", "no-such-profile")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("unknown profile", proc.stderr)

    def test_secret_guard_trips_on_planted_token(self):
        proc = self.run_pack("--profiles", "qwen3-coder")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        with open(os.path.join(self.out, "spark", "env.example"), "a",
                  encoding="utf-8") as f:
            f.write("SWITCH_TOKEN=abc123\n")
        proc = self.run_pack("--resume", "--profiles", "qwen3-coder")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("secret guard", proc.stderr)
        self.assertIn("SWITCH_TOKEN", proc.stderr)
        self.assertNotIn("abc123", proc.stderr)   # the value is not echoed

        # a planted suspicious FILE NAME is caught too
        with open(os.path.join(self.out, "spark", "deploy.key"), "w",
                  encoding="utf-8") as f:
            f.write("not really a key\n")
        proc = self.run_pack("--resume", "--profiles", "qwen3-coder")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("deploy.key", proc.stderr)


# --------------------------------------------------------- install tests ----


def regenerate_sums(root):
    """Rebuild SHA256SUMS over the bundle's current regular files (symlinks
    are never hashed)."""
    sums = os.path.join(root, "SHA256SUMS")
    if os.path.exists(sums):
        os.remove(sums)
    lines = []
    for rel in sorted(bundle_regular_files(root)):
        with open(os.path.join(root, rel), "rb") as f:
            lines.append(f"{hashlib.sha256(f.read()).hexdigest()}  {rel}")
    with open(sums, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def make_fake_bundle(root, models=((("qwen3-coder", QWEN_MODEL)),),
                     tiktoken=False):
    """A tiny but structurally correct bundle (real HF symlink layout,
    consistent MANIFEST.json + SHA256SUMS)."""

    def w(rel, data):
        path = os.path.join(root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data if isinstance(data, bytes) else data.encode())

    w("k3s/k3s-arm64", K3S_BIN_BYTES)
    w("k3s/k3s-airgap-images-arm64.tar.zst", AIRGAP_BYTES)
    w("k3s/install.sh", b"#!/bin/sh\nexit 0\n")
    w("k3s/sha256sum-arm64.txt", "unused-here  k3s-arm64\n")
    w("images/vllm.tar", b"vllm-image-tar")
    w("images/k8s-device-plugin.tar", b"device-plugin-image-tar")
    w("spark/spark_switch.py", "# controller\n")
    w("spark/install-spark-k8s.sh", b"#!/bin/sh\nexit 0\n")
    w("spark/install-spark-offline.sh", b"#!/bin/sh\nexit 0\n")
    model_entries = []
    for profile, model in models:
        mdir = "models--" + model.replace("/", "--")
        rev = "deadbeef0000"
        w(f"hf/hub/{mdir}/refs/main", rev)
        w(f"hf/hub/{mdir}/blobs/blob1", b"qwen-weights")
        snapdir = os.path.join(root, "hf", "hub", mdir, "snapshots", rev)
        os.makedirs(snapdir, exist_ok=True)
        snapfile = os.path.join(snapdir, "config.json")
        if os.path.lexists(snapfile):   # idempotent re-invocations
            os.remove(snapfile)
        os.symlink("../../blobs/blob1", snapfile)
        model_entries.append({"profile": profile, "model": model,
                              "revision": rev})
    if tiktoken:
        w("hf/tiktoken/o200k_base.tiktoken", b"o200k-encoding")
        w("hf/tiktoken/cl100k_base.tiktoken", b"cl100k-encoding")
    manifest = {
        "format": 1, "created": "2026-11-12T00:00:00Z", "arch": "arm64",
        "k3s_version": K3S_VERSION,
        "images": [
            {"ref": VLLM_REF, "file": "images/vllm.tar",
             "image_id": "sha256:fake"},
            {"ref": "nvcr.io/nvidia/k8s-device-plugin:v0.17.4",
             "file": "images/k8s-device-plugin.tar",
             "image_id": "sha256:fake2"}],
        "models": model_entries, "tiktoken": tiktoken}
    w("MANIFEST.json", json.dumps(manifest, indent=2))
    regenerate_sums(root)


def corrupt_snapshot_symlink(bundle_root, model, link_text):
    """Point the bundle's snapshot symlink at something it must never trust."""
    mdir = "models--" + model.replace("/", "--")
    snap = os.path.join(bundle_root, "hf", "hub", mdir, "snapshots",
                        "deadbeef0000", "config.json")
    if os.path.lexists(snap):
        os.remove(snap)
    os.symlink(link_text, snap)


class InstallOfflineTests(OfflineScriptTestCase):
    def setUp(self):
        super().setUp()
        self.install_stub("sudo", SUDO_STUB)
        self.install_stub("uname", UNAME_STUB)
        self.install_stub("df", DF_STUB)
        self.install_stub("nvidia-container-runtime", RUNTIME_STUB)
        self.bundle = os.path.join(self.tmp, "bundle")
        make_fake_bundle(self.bundle)
        self.hf_cache = os.path.join(self.tmp, "hf-dest")
        self.env["HF_CACHE_DIR"] = self.hf_cache

    def run_install(self, *args, **env_over):
        return self.run_script(INSTALL_SCRIPT, "--bundle", self.bundle,
                               *args, **env_over)

    def test_default_action_verifies_good_bundle(self):
        proc = self.run_install()
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("verified:", proc.stdout)
        self.assertIn("check every HF snapshot symlink", proc.stdout)
        self.assertEqual(self.lines_with("sudo "), [])
        # next-step hints point at the bundle's spark/ copy
        self.assertIn("OFFLINE=1 ./install-spark-k8s.sh --dry-run",
                      proc.stdout)
        self.assertIn("--migrate-from-docker", proc.stdout)

    def test_flipped_byte_fails_verify_and_blocks_every_action(self):
        with open(os.path.join(self.bundle, "images", "vllm.tar"), "ab") as f:
            f.write(b"!")
        proc = self.run_install("--all")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("checksum mismatch: images/vllm.tar", proc.stderr)
        # verify runs before every action: nothing else executed at all
        self.assertEqual(self.lines_with("sudo "), [])
        self.assertFalse(os.path.exists(self.hf_cache))
        self.assertFalse(os.path.exists(os.path.join(self.home, ".kube")))

    def test_verify_refuses_wrong_host_arch(self):
        proc = self.run_install(STUB_UNAME_M="x86_64")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("arm64-only", proc.stderr)

    def test_verify_refuses_bad_manifest_arch(self):
        path = os.path.join(self.bundle, "MANIFEST.json")
        with open(path, encoding="utf-8") as f:
            man = json.load(f)
        man["arch"] = "amd64"
        with open(path, "w", encoding="utf-8") as f:
            json.dump(man, f)
        proc = self.run_install()
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("expected arm64", proc.stderr)

    def test_verify_rejects_unsafe_snapshot_symlinks(self):
        # the bundle is UNTRUSTED input: an absolute link, an escaping
        # traversal and a dangling link must all fail verify — before
        # anything is copied anywhere.
        cases = [
            ("/etc/passwd", "absolute symlink"),
            ("../../../../etc/passwd", "escapes"),
            ("../../blobs/no-such-blob", "target blob missing"),
        ]
        for link_text, marker in cases:
            with self.subTest(link=link_text):
                corrupt_snapshot_symlink(self.bundle, QWEN_MODEL, link_text)
                proc = self.run_install("--load-models")
                self.assertNotEqual(proc.returncode, 0)
                self.assertIn("unsafe HF cache", proc.stderr)
                self.assertIn(marker, proc.stderr)
                self.assertFalse(os.path.exists(self.hf_cache))

    def test_verify_rejects_regular_file_in_snapshots(self):
        # a planted regular file where only symlinks-into-blobs may live
        mdir = "models--" + QWEN_MODEL.replace("/", "--")
        snap = os.path.join(self.bundle, "hf", "hub", mdir, "snapshots",
                            "deadbeef0000", "config.json")
        os.remove(snap)
        with open(snap, "wb") as f:
            f.write(b"planted")
        proc = self.run_install("--load-models")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("regular file inside snapshots/", proc.stderr)
        self.assertFalse(os.path.exists(self.hf_cache))

    def test_install_k3s_argv_and_kubeconfig(self):
        proc = self.run_install("--install-k3s")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        calls = self.calls()

        self.assertTrue(self.lines_with(
            f"sudo install -m 0755 {self.bundle}/k3s/k3s-arm64 "
            "/usr/local/bin/k3s"))
        self.assertTrue(self.lines_with(
            "sudo mkdir -p /var/lib/rancher/k3s/agent/images"))
        self.assertTrue(self.lines_with(
            f"sudo cp {self.bundle}/k3s/k3s-airgap-images-arm64.tar.zst "
            "/var/lib/rancher/k3s/agent/images/"))
        # the workload image tars ride along for k3s to import at start
        self.assertTrue(self.lines_with(
            f"sudo cp {self.bundle}/images/vllm.tar "
            "/var/lib/rancher/k3s/agent/images/"))
        self.assertTrue(self.lines_with(
            f"sudo cp {self.bundle}/images/k8s-device-plugin.tar "
            "/var/lib/rancher/k3s/agent/images/"))

        # memlock drop-in written via sudo tee from a captured string
        tee = [line for line in calls if "tee /etc/systemd/system/"
               "k3s.service.d/memlock.conf" in line]
        self.assertEqual(len(tee), 1)
        self.assertIn("[Service]", tee[0])
        self.assertIn("LimitMEMLOCK=infinity", self.log_text())

        env_call = self.lines_with("sudo env")
        self.assertEqual(len(env_call), 1)
        self.assertIn("INSTALL_K3S_SKIP_DOWNLOAD=true", env_call[0])
        self.assertIn(f"INSTALL_K3S_VERSION={K3S_VERSION}", env_call[0])
        self.assertIn("INSTALL_K3S_EXEC=--disable traefik "
                      "--write-kubeconfig-mode 600 --secrets-encryption",
                      env_call[0])
        self.assertTrue(env_call[0].endswith(f" sh {self.bundle}/k3s/install.sh"))

        # the install waits for a non-empty kubeconfig before copying it
        self.assertTrue(self.lines_with(
            "sudo test -s /etc/rancher/k3s/k3s.yaml"))
        # user-owned kubeconfig copied from the root one, mode 600, no
        # group/world-readable window and no leftover temp file
        self.assertTrue(self.lines_with("sudo cat /etc/rancher/k3s/k3s.yaml"))
        kubeconfig = os.path.join(self.home, ".kube", "config")
        with open(kubeconfig, encoding="utf-8") as f:
            self.assertEqual(f.read(), "apiVersion: v1\nkind: Config\n")
        mode = stat.S_IMODE(os.stat(kubeconfig).st_mode)
        self.assertEqual(mode, 0o600)
        self.assertFalse(os.path.exists(
            os.path.join(self.home, ".kube", "config.offline-tmp")))

        # install-k3s never touches the image import or model copy paths
        self.assertEqual(self.lines_with("images import"), [])
        self.assertFalse(os.path.exists(self.hf_cache))

    def test_install_k3s_fails_when_kubeconfig_never_appears(self):
        # K3S_KUBECONFIG_WAIT_SECONDS=0 keeps the test instant: the poll is
        # skipped and the missing kubeconfig is reported immediately
        proc = self.run_install("--install-k3s",
                                STUB_SUDO_K3SYAML_RC=1,
                                K3S_KUBECONFIG_WAIT_SECONDS=0)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("did not write /etc/rancher/k3s/k3s.yaml", proc.stderr)
        self.assertEqual(self.lines_with("sudo cat "), [])   # never copied
        self.assertFalse(os.path.exists(os.path.join(self.home, ".kube")))

    def test_install_k3s_disk_preflight_fails_before_any_sudo_copy(self):
        proc = self.run_install("--install-k3s", STUB_DF_AVAIL_KB=0)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("not enough free space", proc.stderr)
        for write in ("sudo install ", "sudo mkdir", "sudo cp ", "sudo env",
                      "sudo tee ", "sudo cat "):
            self.assertEqual(self.lines_with(write), [],
                             f"disk preflight did not gate: {write}")
        self.assertFalse(os.path.exists(os.path.join(self.home, ".kube")))

    def test_missing_nvidia_runtime_fails_before_any_sudo_write(self):
        self.remove_stub("nvidia-container-runtime")
        proc = self.run_install("--install-k3s")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("nvidia-container-runtime", proc.stderr)
        self.assertIn("NOT part of the bundle", proc.stderr)
        for write in ("sudo install ", "sudo tee ", "sudo mkdir",
                      "sudo cp ", "sudo env", "sudo cat "):
            self.assertEqual(self.lines_with(write), [],
                             f"preflight did not gate: {write}")
        self.assertFalse(os.path.exists(os.path.join(self.home, ".kube")))

    def test_existing_k3s_with_other_version_refused(self):
        self.install_stub("k3s", K3S_STUB)
        proc = self.run_install("--install-k3s", STUB_K3S_INSTALLED="v1.32.4+k3s1")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("v1.32.4+k3s1", proc.stderr)
        self.assertIn(K3S_VERSION, proc.stderr)
        self.assertEqual(self.lines_with("sudo install "), [])

    def test_existing_k3s_version_parsed_from_first_line_only(self):
        # `k3s --version` line 2 ("go version ...") must not be mistaken for
        # the installed version
        self.install_stub("k3s", K3S_STUB)
        proc = self.run_install("--install-k3s", STUB_K3S_INSTALLED=K3S_VERSION)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("already installed; skipping", proc.stdout)
        self.assertEqual(self.lines_with("sudo install "), [])
        self.assertEqual(self.lines_with("sudo env"), [])

    def test_load_images_imports_every_tar_and_checks_refs(self):
        proc = self.run_install("--load-images",
                                STUB_CTR_REFS=f"{VLLM_REF}\n"
                                              "nvcr.io/nvidia/k8s-device-"
                                              "plugin:v0.17.4")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        imports = self.lines_with("images import")
        self.assertEqual(len(imports), 2, imports)
        self.assertTrue(any("images/vllm.tar" in line for line in imports))
        self.assertTrue(any("images/k8s-device-plugin.tar" in line
                            for line in imports))
        self.assertTrue(self.lines_with("sudo -n k3s ctr version"))
        self.assertTrue(self.lines_with("images ls -q"))
        self.assertIn("all MANIFEST image refs are present", proc.stdout)

        # a ctr listing without the refs fails the verification
        proc = self.run_install("--load-images", STUB_CTR_REFS="")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("was not imported into containerd", proc.stderr)

    def test_load_images_requires_exact_ctr_line_match(self):
        # a SUPERSTRING line ("...:26.02-py3-with-extra") must not satisfy
        # the ref "...:26.02-py3" — presence is an exact line comparison
        proc = self.run_install(
            "--load-images",
            STUB_CTR_REFS=f"{VLLM_REF}-with-extra\n"
                          "nvcr.io/nvidia/k8s-device-plugin:v0.17.4")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn(VLLM_REF, proc.stderr)
        self.assertIn("was not imported into containerd", proc.stderr)

    def test_load_models_preserves_symlinks_and_refuses_differing_files(self):
        make_fake_bundle(self.bundle, tiktoken=True)
        proc = self.run_install("--load-models")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

        mdir = "models--" + QWEN_MODEL.replace("/", "--")
        dest = os.path.join(self.hf_cache, "hub", mdir)
        snap = os.path.join(dest, "snapshots", "deadbeef0000", "config.json")
        self.assertTrue(os.path.islink(snap), snap)   # symlink preserved
        with open(os.path.join(dest, "refs", "main"), encoding="utf-8") as f:
            self.assertEqual(f.read(), "deadbeef0000")
        self.assertTrue(os.path.isfile(
            os.path.join(self.hf_cache, "tiktoken", "o200k_base.tiktoken")))
        self.assertTrue(os.path.isfile(
            os.path.join(self.hf_cache, "tiktoken", "cl100k_base.tiktoken")))

        # re-running is safe: identical blobs and encodings are skipped
        proc = self.run_install("--load-models")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("identical skipped", proc.stdout)

        # a DIFFERING existing file is refused and named
        with open(os.path.join(dest, "blobs", "blob1"), "wb") as f:
            f.write(b"different-bytes")
        proc = self.run_install("--load-models")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("refusing to overwrite a differing file", proc.stderr)
        self.assertIn(os.path.join("blobs", "blob1"), proc.stderr)
        with open(os.path.join(dest, "blobs", "blob1"), "rb") as f:
            self.assertEqual(f.read(), b"different-bytes")   # not clobbered

    def test_tiktoken_never_overwrites_a_differing_file(self):
        make_fake_bundle(self.bundle, tiktoken=True)
        proc = self.run_install("--load-models")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

        # plant a DIFFERING encoding at the destination -> refuse, keep both
        target = os.path.join(self.hf_cache, "tiktoken", "o200k_base.tiktoken")
        with open(target, "wb") as f:
            f.write(b"user-owned-encoding")
        proc = self.run_install("--load-models")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("refusing to overwrite a differing tiktoken file",
                      proc.stderr)
        with open(target, "rb") as f:
            self.assertEqual(f.read(), b"user-owned-encoding")

    def test_tiktoken_bundle_may_not_carry_symlinks(self):
        make_fake_bundle(self.bundle, tiktoken=True)
        enc = os.path.join(self.bundle, "hf", "tiktoken",
                           "o200k_base.tiktoken")
        os.remove(enc)
        os.symlink("../../k3s/install.sh", enc)
        regenerate_sums(self.bundle)   # keep checksums consistent
        proc = self.run_install("--load-models")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("tiktoken bundle contains a symlink", proc.stderr)
        # validation runs before ANY copy: no tiktoken dir was created
        self.assertFalse(os.path.exists(
            os.path.join(self.hf_cache, "tiktoken")))

    def test_load_models_checks_free_space(self):
        proc = self.run_install("--load-models", STUB_DF_AVAIL_KB=0)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("not enough free space", proc.stderr)
        self.assertFalse(os.path.exists(self.hf_cache))

    def test_load_models_space_need_counts_only_missing_files(self):
        # after a successful load every bundle file already exists with the
        # same size at the destination: the need drops to 0 KB, so even a
        # nearly-full disk (0 KB free) passes the preflight
        make_fake_bundle(self.bundle, tiktoken=True)
        proc = self.run_install("--load-models")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        proc = self.run_install("--load-models", STUB_DF_AVAIL_KB=0)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_load_models_df_probes_nearest_existing_ancestor(self):
        # a deep, not-yet-existing HF_CACHE_DIR: df must be pointed at the
        # nearest ancestor that exists (self.tmp), not at the missing path
        deep = os.path.join(self.tmp, "no", "such", "deep", "hf")
        proc = self.run_install("--load-models", HF_CACHE_DIR=deep)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn(f"df -Pk {self.tmp}", self.log_text())
        self.assertNotIn("df -Pk " + deep, self.log_text())

    def test_no_network_stub_ever_called_by_install(self):
        for stub in ("curl", "wget", "docker", "hf", "huggingface-cli"):
            self.install_stub(stub, "#!/bin/sh\nexit 0\n")
        proc = self.run_install("--all",
                                STUB_CTR_REFS=f"{VLLM_REF}\n"
                                              "nvcr.io/nvidia/k8s-device-"
                                              "plugin:v0.17.4")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        for stub in ("curl ", "wget ", "docker ", "hf ",
                     "huggingface-cli "):
            self.assertEqual(self.lines_with(stub), [],
                             f"install-spark-offline.sh called: {stub}")

    def test_dry_run_changes_nothing(self):
        proc = self.run_install("--all", "--dry-run")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("verified:", proc.stdout)   # verify still runs
        for write in ("sudo install ", "sudo tee ", "sudo mkdir",
                      "sudo cp ", "sudo env", "sudo cat ",
                      "images import"):
            self.assertEqual(self.lines_with(write), [],
                             f"dry-run executed: {write}")
        self.assertIn("+ sudo install -m 0755", proc.stdout)
        self.assertFalse(os.path.exists(self.hf_cache))
        self.assertFalse(os.path.exists(os.path.join(self.home, ".kube")))


# ------------------------------------------------------ static guarantees ----


class StaticSourceTests(unittest.TestCase):
    def test_install_offline_source_has_no_network_tools_at_all(self):
        with open(INSTALL_SCRIPT, encoding="utf-8") as f:
            text = f.read()
        for banned in ("curl", "wget", "docker pull", "hf download",
                       "huggingface-cli", "http://", "https://"):
            self.assertNotIn(banned, text,
                             f"install-spark-offline.sh mentions {banned!r}")
        self.assertNotIn("| grep -q", text)

    def test_scripts_parse_and_avoid_portability_traps(self):
        for script in (PACK_SCRIPT, INSTALL_SCRIPT, K8S_SCRIPT):
            proc = subprocess.run(["bash", "-n", script],
                                  capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            proc = subprocess.run(["/bin/bash", "-n", script],
                                  capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            with open(script, encoding="utf-8") as f:
                text = f.read()
            self.assertIn("set -euo pipefail", text)
            code = "\n".join(ln for ln in text.splitlines()
                             if not ln.lstrip().startswith("#"))
            for banned in ("set -x", "| grep -q", "sed -i", "readlink -f",
                           "mapfile", "declare -A", " timeout ",
                           "${var,,}"):
                self.assertNotIn(banned, code, f"{script}: {banned}")
            mode = stat.S_IMODE(os.stat(script).st_mode)
            self.assertEqual(mode & 0o111, 0o111, f"{script} not executable")

    def test_pack_never_dereferences_hf_symlinks(self):
        with open(PACK_SCRIPT, encoding="utf-8") as f:
            text = f.read()
        code = "\n".join(ln for ln in text.splitlines()
                         if not ln.lstrip().startswith("#"))
        self.assertNotIn("cp -L", code)
        self.assertNotIn("cp -RL", code)
        self.assertNotIn("cp -RP ", code)   # the cache copy is file-by-file


# ------------------------------------------------- controller offline key ----


class VllmOfflineConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.env_file = os.path.join(self.tmp, "env")
        with open(self.env_file, "w", encoding="utf-8") as f:
            f.write(TOKEN_LINE)
            f.write("HF_CACHE_HOST=" + os.path.join(self.tmp, "hf") + "\n")
        os.chmod(self.env_file, 0o600)

    def test_default_is_off(self):
        import spark_switch
        cfg = spark_switch.load_config(self.env_file, {})
        self.assertIs(cfg.vllm_offline, False)

    def test_one_and_zero_are_accepted(self):
        import spark_switch
        cfg = spark_switch.load_config(self.env_file, {"VLLM_OFFLINE": "1"})
        self.assertIs(cfg.vllm_offline, True)
        cfg = spark_switch.load_config(self.env_file, {"VLLM_OFFLINE": "0"})
        self.assertIs(cfg.vllm_offline, False)
        with open(self.env_file, "a", encoding="utf-8") as f:
            f.write("VLLM_OFFLINE=1\n")
        cfg = spark_switch.load_config(self.env_file, {})
        self.assertIs(cfg.vllm_offline, True)

    def test_anything_else_is_a_config_error(self):
        import spark_switch
        for bad in ("yes", "true", "on", "2"):
            with self.assertRaises(spark_switch.ConfigError):
                spark_switch.load_config(self.env_file,
                                         {"VLLM_OFFLINE": bad})


class BuildCreateBodyOfflineTests(unittest.TestCase):
    def _bodies(self):
        import spark_backend_docker
        import spark_switch
        profiles = spark_switch.load_profiles(PROFILES_PATH)
        profile = profiles["qwen3-coder"]
        cfg = spark_switch.Config()
        cfg.vllm_api_key = "sk-test-key"
        cfg.hf_cache_host = "/hf"
        body_off = spark_backend_docker.build_create_body(cfg, profile)
        cfg.vllm_offline = True
        body_on = spark_backend_docker.build_create_body(cfg, profile)
        return body_off, body_on

    def test_offline_off_is_byte_identical_to_legacy_body(self):
        body_off, _ = self._bodies()
        self.assertEqual(body_off["Env"], ["VLLM_API_KEY=sk-test-key"])
        self.assertEqual(body_off["Cmd"][0], "vllm")
        self.assertNotIn("HF_HUB_OFFLINE", json.dumps(body_off))

    def test_offline_on_appends_the_three_env_vars_after_the_key(self):
        body_off, body_on = self._bodies()
        self.assertEqual(
            body_on["Env"],
            ["VLLM_API_KEY=sk-test-key",
             "HF_HUB_OFFLINE=1",
             "TRANSFORMERS_OFFLINE=1",
             "TIKTOKEN_ENCODINGS_BASE=/root/.cache/huggingface/tiktoken"])
        # everything EXCEPT Env is unchanged
        only_env = dict(body_on)
        only_env["Env"] = body_off["Env"]
        self.assertEqual(only_env, body_off)


if __name__ == "__main__":
    unittest.main()
