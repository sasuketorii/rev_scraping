---
name: naming-normalization-guard
description: Use when adding, importing, renaming, or reorganizing Skills and knowledge packs in this repository. Enforces the project naming policy, updates internal references, preserves required skill entrypoint filenames, and checks for stale paths before commit.
---

# Naming Normalization Guard

この Skill は、REV DevSkills に新しい Skill / knowledge pack / deploy guard を追加したり、既存ファイルをリネームするときに使う。

目的は、名前だけをきれいにすることではない。Codex / Claude Code が読み込む入口、README のコマンド例、内部参照、インストール先、更新プロンプトまで含めて、壊れない形で名前を統一する。

## Rules

- ディレクトリと通常ファイルは `kebab-case` に統一する。
- `README.md`、`SKILL.md`、`AGENTS.md` は規約ファイルなのでリネームしない。
- `references/`、`scripts/`、`prompts/` はそのままのディレクトリ名を使う。
- `*_knowledge_pack_vX_Y_Z` は `<language>-skills-knowledge-pack` にする。
- `payloadcms` のように詰まった製品名は、読みやすい場合だけ `payload-cms` のように分割する。
- version はファイル名に残す必要がある監査レポートだけ `v0.1.2` のように残す。
- `.DS_Store`、`__pycache__/`、`.pyc`、`.claude/` は追跡しない。

## Rename Pattern

```text
goskills_knowledge_pack_v0_1_1
  -> go-skills-knowledge-pack

typescriptskills_knowledge_pack_v0_1_1
  -> typescript-skills-knowledge-pack

rustskills_knowledge_pack_v0_1_2
  -> rust-skills-knowledge-pack

payloadcms-deploy-guard
  -> payload-cms-deploy-guard
```

Within each pack:

```text
rustskills_master.md
  -> rust-skills-master.md

rustskills_sources.md
  -> rust-skills-sources.md

browser_automation_cdp.md
  -> browser-automation-cdp.md
```

## Required Workflow

1. Run `git status --short --branch` and identify unrelated user changes.
2. List candidate paths with `find . -maxdepth 4 -type f | sort`.
3. Rename directories and files with `mv`.
4. Update internal Markdown references and command examples.
5. Update root `README.md` if a new top-level Skill or knowledge pack was added.
6. Add or update `.gitignore` only for generated or tool-local files.
7. Run stale-name checks with `rg`.
8. Run lightweight script checks when scripts were renamed.
9. Show the user the result before commit or push.

## Stale Name Checks

Use a targeted search after every rename:

```bash
rg -n "goskills_|typescriptskills_|rustskills_|payloadcms-deploy-guard|source_links|source_manifest|data_sources|browser_automation|pack_audit|runtime_toolchain|api_crawler|ai_agent" .
```

Expected remaining matches are allowed only when they are package names, URLs, historical text, or generated artifact names that intentionally keep the old token. Everything else should be updated.

## Commit Boundary

Do not bundle unrelated user edits into the rename commit. If files were already modified before the rename work, either leave them unstaged or explicitly call them out before commit.
