# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This repository is a personal collection of reusable agents, skills, slash commands, and related configuration for popular LLM coding harnesses. It contains no application code, build system, or tests — the content is markdown/config definition files organized per harness.

## Structure

Each top-level directory corresponds to one harness, and artifacts for that harness live only in its directory:

- `claude/` — Claude Code (agents, skills, commands)
- `gemini/` — Gemini CLI
- `opencode/` — opencode
- `codex/` — OpenAI Codex CLI

(Only `claude/` exists so far; create the other directories as content is added for those harnesses.)

## Format conventions per harness

When adding or editing definitions, follow the target harness's native format so files can be copied/symlinked directly into a real config directory:

- **Claude Code**: subagents are single `.md` files with YAML frontmatter (`name`, `description`, optionally `tools`, `model`) as used in `.claude/agents/`. Skills are directories containing a `SKILL.md` (frontmatter: `name`, `description`) plus any supporting files, as used in `.claude/skills/`. Slash commands are `.md` files as used in `.claude/commands/`.
- **Gemini CLI**: custom commands are `.toml` files as used in `.gemini/commands/`; context files are `GEMINI.md`.
- **opencode**: agents are `.md` files with YAML frontmatter as used in `.opencode/agent/`.
- **Codex CLI**: context files are `AGENTS.md`; custom prompts are `.md` files as used in `~/.codex/prompts/`.

When porting an agent/skill between harnesses, keep the behavior and prompt content equivalent but translate the metadata/frontmatter to the destination harness's schema — do not copy one harness's frontmatter format into another's folder.
