# Open WebUI + Wiki MCP + Claude Code — offline (air-gapped) bundle

English | [한국어](README.ko.md)

Source for installing and running a local AI workstation **fully offline** on an Apple Silicon Mac
(macOS arm64) with no internet connection:

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
| openwebui-wiki bundle (repo root) | Open WebUI + wiki-mcp | Yes | [`INSTALL.md`](INSTALL.md) |
| Integrated bundle ([`guardian/`](guardian/)) | LM Studio (app + models) + Open WebUI + wiki-mcp + Claude Code (`claude-lms`) | No: it needs a base bundle (below) | [`guardian/README.md`](guardian/README.md), [`docs/INSTALL-ISSUES.md`](docs/INSTALL-ISSUES.md) |

### What is in this repo, and what is not

In the repo:

- the wiki-mcp source, and the install and packaging scripts of the openwebui-wiki bundle
- `guardian/build-merged-bundle.sh`, which adds the wiki layer, the bge-m3 embedding model, the official
  LM Studio dmg and Claude Code to a base bundle
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
- To install it on its own, put the `claude` binary, its version in `VERSION`, `install-claude-code.sh` and
  `claude-lms` in one folder and run `./install-claude-code.sh` (the integrated bundle does this as its last step).

## Build the bundle yourself

There is no release to download. This repo keeps **sources and build scripts only**: large binaries do not
belong in git. Build on a Mac with internet access, then copy the bundle to the target Mac.

**openwebui-wiki bundle**: fill `openwebui-packages/` (macOS arm64, cp311 and cp312 wheels), then run `./package.sh`.

```bash
# build Mac (macOS arm64 · Python 3.12 · Xcode Command Line Tools for the OCR helper · online)
# example; for the extra wheels see the INSTALL.md appendix (SKIP_OCR=1 packages without OCR)
python3.12 -m pip download open-webui==0.12.3 mcpo==0.0.20 ./wiki-mcp -d openwebui-packages
./package.sh                        # → dist/openwebui-wiki-bundle-<version>-macos-arm64.tar.gz (+ .sha256)
```

**Integrated bundle**: `guardian/build-merged-bundle.sh` merges a base bundle made by `build-llm-bundle.sh`
with the official LM Studio dmg. See [`guardian/README.md`](guardian/README.md).

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

```bash
./install.sh              # offline install (uv + local wheels) into .venv
source .venv/bin/activate
export HF_HUB_OFFLINE=1 OFFLINE_MODE=1
open-webui serve          # http://localhost:8080
./run-wiki-mcp.sh watch   # watch raw/ → convert to wiki notes
```

raw → wiki conversion is off by default: set `WIKI_INGEST_ENABLED=1`, `WIKI_INGEST_MODEL` and
`WIKI_INGEST_API_KEY` first (see INSTALL.md). Without them, `watch` only reindexes.

## Docs (Korean)

| Doc | Contents |
| --- | --- |
| [`INSTALL.md`](INSTALL.md) | **Install and setup**: offline install, the 15 tools, templates, raw conversion, chunking, extraction, OCR |
| [`docs/USAGE.md`](docs/USAGE.md) | **User manual**: connecting and checking each part after install (Open WebUI) |
| [`docs/OPERATIONS.md`](docs/OPERATIONS.md) | **Operations**: starting services, launchd autostart, health checks, backups |
| [`docs/TESTING.md`](docs/TESTING.md) | **Test strategy**: targets, priorities, how to run |
| [`docs/KNOWLEDGE-BASE.md`](docs/KNOWLEDGE-BASE.md) | **Building knowledge**: atomic-note rules, what to feed in, quality tuning, upkeep |
| [`docs/LM-STUDIO.md`](docs/LM-STUDIO.md) | **LM Studio**: chat, Knowledge embeddings, sharing it with Wiki MCP, air-gap settings |
| [`docs/INSTALL-ISSUES.md`](docs/INSTALL-ISSUES.md) | **Install pitfalls**: every problem met on clean Macs and how it was fixed |

After installing, start with the checklist in [`docs/USAGE.md`](docs/USAGE.md).

## Requirements (prepare on the target Mac)

| Item | Note |
| --- | --- |
| macOS (Apple Silicon / arm64) | the bundled wheels are arm64 only |
| `uv` 0.5+ | on an air-gapped Mac, bring the binary in beforehand |
| Python 3.11 or 3.12 | install beforehand: uv cannot download it offline |
| `openwebui-packages/` | **offline wheel repository (~834MB)**, not in this repo (see above) |

## Repository layout (sources only)

```text
INSTALL.md            # full manual (single reference)
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
