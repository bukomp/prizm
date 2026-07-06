# prizm

One def in, every harness out.

**prizm** is a single-file, pure-bash transpiler that turns unified TOML definitions into native **agents**, **skills**, and **slash commands** for four LLM coding harnesses:

| Harness | Agents | Skills | Commands |
|---|---|---|---|
| Claude Code | `claude/agents/*.md` | `claude/skills/*/SKILL.md` | `claude/commands/*.md` |
| Gemini CLI | `gemini/agents/*.md` | `gemini/skills/*/SKILL.md` | `gemini/commands/*.toml` |
| opencode | `opencode/agents/*.md` | `opencode/skills/*/SKILL.md` | `opencode/commands/*.md` |
| Codex CLI | `codex/agents/*.toml` | `codex/skills/*/SKILL.md` | `codex/prompts/*.md` ¹ |

¹ Codex prompts are deprecated; set `emit = "skill"` in the `[codex]` table to ship a skill instead.

Each harness invented its own frontmatter, field names, argument syntax, and directory layout. Writing the same agent four times means it drifts four ways. With prizm you author one `defs/<name>.<kind>.toml` and the build emits every native format, verified against each harness's official docs.

## Quick start

```sh
cp defs/_template.skill.toml defs/my-skill.skill.toml
$EDITOR defs/my-skill.skill.toml
./prizm                      # build everything (or: ./prizm defs/my-skill.skill.toml)
```

The artifact's name and kind come from the file name. Requires bash 4+, nothing else.

## The def language

A TOML subset with one shared `body` (the prompt) plus a `[claude]` / `[gemini]` / `[opencode]` / `[codex]` table per harness holding that harness's fields under their real native names. Portable body syntax is rewritten per harness:

- `$ARGUMENTS` and 1-based `$1..$9` — positional args (Claude's 0-based convention handled automatically)
- `` !`cmd` `` — inline shell where supported, a bracketed run-this-command instruction where not
- `<!-- only: claude, gemini --> … <!-- /only -->` — body section for listed harnesses only

Escape hatches: `raw = '''…'''` injects verbatim metadata (nested permission maps, hooks, extra tables), `body = '''…'''` overrides the shared body per harness. Anything unparseable is a hard build error: prizm never emits a mangled value.

The full language reference lives in the header comment of [`prizm`](prizm); the [`defs/_template.*.toml`](defs/) files enumerate every documented field of every harness.

## Layout

- `defs/` — the source of truth: your defs plus `_template.*.toml` (all-fields-documented, skipped by the build)
- `prizm` — the transpiler
- `claude/`, `gemini/`, `opencode/`, `codex/` — build output, gitignored; never edit by hand
