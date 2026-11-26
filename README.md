# Open WebUI + Wiki MCP + Claude Code — offline (air-gapped) bundle

English | [한국어](README.ko.md)

Source for installing and running a local AI workstation **fully offline** on an Apple Silicon Mac
(macOS arm64) with no internet connection. The product is the **guardian integrated bundle**
([`guardian/`](guardian/)): one `.tar.xz` that `install-llm-wiki.sh` checks against its `.sha256` and turns into a full install.
The repo root also keeps the older standalone openwebui-wiki bundle (see [Two bundles](#two-bundles)).

- **LM Studio** runs the models locally (Gemma-4-E4B for chat, bge-m3 for embeddings)
- **Open WebUI** is the chat front end
- **wiki-mcp** is an MCP server where an LLM turns raw documents into a linked Markdown wiki ("LLM-wiki")
- **Claude Code** runs as the coding agent on the local model, through the `claude-lms` wrapper

> The detailed manuals (`INSTALL.md`, `docs/`, `guardian/README.md`) are written in Korean.

## What it does

```text
documents into raw/        →  LLM conversion        →  atomic notes in wiki/   →  search and use
(txt/md/PDF/docx/xlsx/        (extraction, chunking,    (graph of [[id]] links)     (15 MCP tools)
 pptx/html/images)             OCR)
```

- **Offline install**: installs from a local wheel repository only, with the network fully cut off
- **raw → wiki**: drop in a source document and the LLM writes atomic notes, including the links between them
- **Long-document chunking**: outline first, then write note by note, so one document becomes many notes
- **Extraction + OCR**: PDF/Word/Excel/PPT/HTML; scanned PDFs and images go through Apple Vision OCR (offline)
- **Note templates**: `wiki/.templates/*.md` sets the frontmatter and section layout
- **Hybrid search**: BM25 + embeddings. For Korean notes, bge-m3 ranked the right note first in 14 of 14 test
  queries; nomic did in 3 of 14

## Two bundles

| Bundle | Contents | Built from this repo alone? | Docs |
| --- | --- | --- | --- |
| Integrated bundle ([`guardian/`](guardian/)) — **the product** | LM Studio (app + models) + Open WebUI + wiki-mcp + Claude Code (`claude-lms`) | No: it needs a base bundle (below) | [`guardian/README.md`](guardian/README.md), [`docs/INSTALL-ISSUES.md`](docs/INSTALL-ISSUES.md) |
| openwebui-wiki bundle (repo root) — old standalone flow | Open WebUI + wiki-mcp | Yes | [`INSTALL.md`](INSTALL.md) |

The integrated bundle installs from three files (`<name>.tar.xz`, `<name>.tar.xz.sha256`,
`install-llm-wiki.sh`) — see [Quick start](#quick-start).

### What is in this repo, and what is not

In the repo:

- the wiki-mcp source, and the install and packaging scripts of the openwebui-wiki bundle
- `guardian/build-merged-bundle.sh`, which adds the wiki layer, the bge-m3 embedding model, the official
  LM Studio dmg and Claude Code to a base bundle
- `guardian/install-llm-wiki.sh` and `guardian/pack-bundle.sh` — the one-step installer for the target
  Mac, and the packer that writes the three files it needs (`.tar.xz`, `.sha256`, installer)
- `guardian/claude-lms` and `guardian/install-claude-code.sh` (Claude Code on LM Studio)
- the install-pitfall log ([`docs/INSTALL-ISSUES.md`](docs/INSTALL-ISSUES.md)) and the manuals

Not in the repo:

- large binaries: the wheel repository (~834MB), the models, the LM Studio dmg
- the Claude Code binary: `build-merged-bundle.sh` copies the one installed on the build Mac
  (`~/.local/bin/claude`) after checking that it carries Anthropic's signature
- the **base bundle builder** (server-guardian's `build-llm-bundle.sh`: LM Studio runtimes, the chat model,
  the bundled Python and the Open WebUI wheels). It lives in a separate repository that is not public yet,
  so the integrated bundle cannot be rebuilt from this repo alone

## Claude Code, offline (`claude-lms`)

`claude-lms` points Claude Code at LM Studio (`ANTHROPIC_BASE_URL`), so no Anthropic account or API key is
needed. It turns off nonessential traffic and auto-update. Claude Code's system prompt and tool definitions
alone are about 10k tokens, while a just-in-time load in LM Studio gets the default context (4k–8k), which
cuts the prompt off. So the wrapper loads the model with a 64k context first.

- The model is local; Claude (Anthropic's model) does not run here. Plain `claude` still needs an Anthropic login.
- A 4B model is weak at agentic work: name the tools you want ("Read calc.py, fix it with Edit, run it with
  Bash") and check every result.
- Zero outbound traffic is the design goal; a full audit on a cut-off network is still to do.
- To install it on its own, put the `claude` binary, its version in `VERSION`, `install-claude-code.sh`,
  `claude-lms` and `claude-kit/` in one folder and run `./install-claude-code.sh` (the integrated bundle does this as its last step).
- The same installer puts the Korean document skill `hwpx` (read, Markdown to HWPX, form filling) in
  `~/.claude/skills/hwpx` (`--no-skills` skips it). Call it as `/hwpx …` in `claude-lms`. See [`docs/CLAUDE-LMS-MANUAL.md`](docs/CLAUDE-LMS-MANUAL.md) (Korean).

## Add-ons: skill-guard and docgen

- **skill-guard** — a `PreToolUse` hook that ships with each skill. When the same `Skill` is called
  again in one session, it rejects the call and answers with the Bash command to run instead, cutting
  the repeat-call loop of a small model. See [`docs/dev/CLAUDE-LMS-SKILLS.md`](docs/dev/CLAUDE-LMS-SKILLS.md) §6.5 (Korean).
- **docgen** — an Open WebUI Tool that writes docx/pptx/xlsx from chat and returns a download link.
  `install-wiki.sh` puts `open-webui-tools/` and `document-templates/` into `~/llm-wiki/`; registering
  the Tool in Open WebUI is a manual step. See [`docs/DOCUMENT-TOOL.md`](docs/DOCUMENT-TOOL.md) (Korean).

## Build the bundle yourself

This repo publishes no ready-made release of its own; it keeps **sources and build scripts only** —
large binaries do not belong in git. Build on a Mac with internet access and copy the bundle to the
target Mac. A maintainer can then upload the result to the Release page of their own Gitea server
(see [Release (maintainers)](#release-maintainers)).

**openwebui-wiki bundle**: fill `openwebui-packages/` (macOS arm64, cp311 and cp312 wheels), then run `./package.sh`.

```bash
# build Mac (macOS arm64 · Python 3.12 · Xcode Command Line Tools for the OCR helper · online)
# example; for the extra wheels see the INSTALL.md appendix (SKIP_OCR=1 packages without OCR)
python3.12 -m pip download open-webui==0.12.3 mcpo==0.0.20 ./wiki-mcp -d openwebui-packages
./package.sh                        # → dist/openwebui-wiki-bundle-<version>-macos-arm64.tar.gz (+ .sha256)
```

**Integrated bundle**: `guardian/build-merged-bundle.sh` merges a base bundle made by `build-llm-bundle.sh`
with the official LM Studio dmg. See [`guardian/README.md`](guardian/README.md). The build's last step
(`guardian/pack-bundle.sh`) writes the three files the target Mac needs next to the bundle:
`<name>.tar.xz`, `<name>.tar.xz.sha256` and `install-llm-wiki.sh`.

```bash
guardian/build-merged-bundle.sh dist/build/<base bundle> \
    --lmstudio-dmg=LM-Studio-<version>-arm64.dmg --name=llm-wiki-bundle-<UTC time>-macos-arm64
```

Copy the openwebui-wiki bundle to the target Mac and install it:

```bash
shasum -a 256 -c openwebui-wiki-bundle-<version>-macos-arm64.tar.gz.sha256
tar -xzf openwebui-wiki-bundle-<version>-macos-arm64.tar.gz
cd openwebui-wiki-bundle-<version>-macos-arm64
./install.sh
```

No sudo and no downloads are needed on the target Mac.

## Quick start

**Integrated bundle (the product)** — copy the three files that the build made
(`<name>.tar.xz`, `<name>.tar.xz.sha256`, `install-llm-wiki.sh`) into one folder on the target
Mac (e.g. `~/bundles`), then run the installer (as in [`guardian/README.md`](guardian/README.md)):

```bash
cd ~/bundles                           # the folder holding the three files
bash install-llm-wiki.sh --dry-run     # checksum and free-space checks, extract, show what it would do
bash install-llm-wiki.sh               # install + start + LM Studio first launch + the wiki pass again
```

No sudo and no downloads are needed. When it finishes, Open WebUI is at http://localhost:8080 and
the wiki services run as LaunchAgents (`dev.guardian.*`). First checks and the tool list:
[`docs/USAGE.md`](docs/USAGE.md). raw → wiki conversion is already configured here (it talks to
LM Studio at `127.0.0.1:1234` directly).

> **Old flow (standalone bundle)** — install the repo-root bundle by hand:

```bash
./install.sh              # offline install (uv + local wheels) into .venv
source .venv/bin/activate
export HF_HUB_OFFLINE=1 OFFLINE_MODE=1
open-webui serve          # http://localhost:8080
./run-wiki-mcp.sh watch   # watch raw/ → convert to wiki notes
```

raw → wiki conversion is off by default in this bundle: set `WIKI_INGEST_ENABLED=1`,
`WIKI_INGEST_MODEL` and `WIKI_INGEST_API_KEY` first (see INSTALL.md). Without them, `watch` only
reindexes.

## Docs (Korean)

| Doc | Contents |
| --- | --- |
| [`guardian/README.md`](guardian/README.md) | **Install (current, integrated bundle)**: contents, the `install-llm-wiki.sh` flow, building the bundle, operations |
| [`docs/INSTALL-GUIDE.md`](docs/INSTALL-GUIDE.md) | **Field install guide (integrated bundle)**: the three files, dry-run, the 7 install steps, options, post-install checks, troubleshooting |
| [`INSTALL.md`](INSTALL.md) | **Install (old standalone-bundle flow, reference)**: offline install, the 15 tools, templates, raw conversion, chunking, extraction, OCR |
| [`docs/USAGE.md`](docs/USAGE.md) | **User manual**: connecting and checking each part after install (Open WebUI) |
| [`docs/OPERATIONS.md`](docs/OPERATIONS.md) | **Operations (integrated bundle)**: service map, daily checks, stop/start order, settings, backups, reindexing, admin password reset, rollback, incident table |
| [`docs/CLAUDE-LMS-MANUAL.md`](docs/CLAUDE-LMS-MANUAL.md) | **claude-lms manual**: offline Claude Code on LM Studio, the `hwpx` skill, the office skills (docx, xlsx, pptx; §11), the skill-guard hook |
| [`docs/dev/CLAUDE-LMS-SKILLS.md`](docs/dev/CLAUDE-LMS-SKILLS.md) | **Skills design and test log**: the `hwpx` skill, skill-guard (§6.5), the live test rounds |
| [`docs/DOCUMENT-TOOL.md`](docs/DOCUMENT-TOOL.md) | **Document generator (docgen)**: registering the docx/pptx/xlsx Tool in Open WebUI |
| [`docs/LLM-ROUTER.md`](docs/LLM-ROUTER.md) | **llm-router (installed by default)**: splits claude-lms requests between a large model on the Spark and LM Studio, `spark-model`, failure behavior |
| [`docs/dev/LLM-ROUTER-TESTING.md`](docs/dev/LLM-ROUTER-TESTING.md) | **llm-router and Spark tests**: the unit-test suites and how to run them |
| [`docs/dev/SPARK-BENCH-REPORT.md`](docs/dev/SPARK-BENCH-REPORT.md) | **DGX Spark benchmarks**: throughput and latency by concurrency, class-size estimates, pre-class advice |
| [`docs/dev/TESTING.md`](docs/dev/TESTING.md) | **Test strategy**: targets, priorities, how to run |
| [`docs/KNOWLEDGE-BASE.md`](docs/KNOWLEDGE-BASE.md) | **Building knowledge**: atomic-note rules, what to feed in, quality tuning, upkeep |
| [`docs/LM-STUDIO.md`](docs/LM-STUDIO.md) | **LM Studio**: chat, Knowledge embeddings, sharing it with Wiki MCP, air-gap settings |
| [`docs/INSTALL-ISSUES.md`](docs/INSTALL-ISSUES.md) | **Install pitfalls**: every problem met on clean Macs and how it was fixed |

Development and test records live in [`docs/dev/`](docs/dev/README.md) (public, not shipped in the field bundle); internal docs live in `docs/internal/` (neither shipped nor published).

After installing, start with the checklist in [`docs/USAGE.md`](docs/USAGE.md).

## Requirements (prepare on the target Mac)

**Integrated bundle (the product)** — from [`guardian/README.md`](guardian/README.md):

| Item | Note |
| --- | --- |
| macOS (Apple Silicon / arm64) | the installer refuses other platforms |
| Free disk space | at least 2.5 × the `.tar.xz` archive + 2 GB |

Nothing else: no sudo, no downloads. A clean Mac's `/usr/bin/tar` reads `.tar.xz` as is.

> **Old flow (standalone bundle)** requirements:

| Item | Note |
| --- | --- |
| macOS (Apple Silicon / arm64) | the bundled wheels are arm64 only |
| `uv` 0.5+ | on an air-gapped Mac, bring the binary in beforehand |
| Python 3.11 or 3.12 | install beforehand: uv cannot download it offline |
| `openwebui-packages/` | **offline wheel repository (~834MB)**, not in this repo (see above) |

## Repository layout (sources only)

```text
INSTALL.md            # standalone-bundle manual (old flow; the current install doc is guardian/README.md)
install.sh            # one-command offline install
package.sh            # builds the release bundle (tar.gz)
run-wiki-mcp.sh       # wiki-mcp launcher (serve | mcpo | watch)
wiki-mcp/src/         # wiki-mcp source (installed editable)
wiki/                 # wiki notes + .templates/ (note templates)
raw/                  # drop source documents here
ocr/vision_ocr.swift  # Apple Vision OCR helper (compiled by package.sh)
guardian/             # integrated bundle: merge script, installers, claude-lms
.env.example          # environment example (cp .env.example .env)
run-openwebui.sh      # Open WebUI launcher (loads .env)
load-env.sh           # shared .env loader
```

> **`openwebui-packages/` (~834MB of wheels) and the release tar.gz are not in the repo.** Large binaries do
> not fit git, so they are built on the build Mac and copied over (see "Build the bundle yourself").

The bundle does not depend on its path: unpack it anywhere and the scripts work relative to where they are.

## Release (maintainers)

How a maintainer uploads a bundle to the Release of their own Gitea server.

```bash
./package.sh     # build the bundle (tar.gz + checksum) → dist/
./release.sh     # upload it to the Gitea Release
```

### Settings: keep the target and the secret apart

| | File | Where | Committed | Contents |
| --- | --- | --- | --- | --- |
| **Target** | `.gitea.conf` | in the repo | ✅ | `GITEA_HOST` / `GITEA_REPO` / `GITEA_API` |
| **Credential** | `~/.config/gitea/hosts/<host>.env` | **outside the repo** | ❌ | `GITEA_TOKEN` only |

**Why the secret lives outside the repo**: `.gitignore` breaks on a pattern typo, `git add -f` or a renamed
file. Outside the repo, committing it by mistake cannot happen at all.

**Why one file per host**: the same credential serves several Gitea servers and projects, and someone who
clones the repo reads the target from `.gitea.conf` and adds **their own token**.

One-time setup:

```bash
mkdir -p ~/.config/gitea/hosts
printf 'GITEA_TOKEN=%s\n' '<your token>' > ~/.config/gitea/hosts/git.example.com.env
chmod 600 ~/.config/gitea/hosts/git.example.com.env
```
Create a token at `https://<host>/user/settings/applications` (scope: `write:repository`).

**Load order**: the `GITEA_TOKEN` environment variable > the credential file > `.gitea.conf` (CI injects it
as an environment variable).

**Safeguard**: if the credential file's permissions are not `600`, the script **refuses to run**.

### Upload endpoint

`GITEA_API` in `.gitea.conf` points **straight at the origin (`git-origin.example.com`)**.
`git.example.com` is behind a Cloudflare proxy that **limits upload bodies to 100MB**, so large bundles
(800MB+) fail there (HTTP 413). Downloads work through either.

## License

[MIT](LICENSE)
