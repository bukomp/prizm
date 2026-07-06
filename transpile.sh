#!/usr/bin/env bash
# transpile.sh — build harness-native agents/skills/commands from unified TOML defs.
#
# Source language: defs/<name>.<kind>.toml — a TOML subset:
#   kind = "skill" | "agent" | "command"    (required)
#   name = "my-thing"                       (required; lowercase-hyphen)
#   description = "..."                     (required in practice)
#   targets = ["claude", "gemini"]          (optional; default: all four harnesses)
#   body = '''                              (the prompt / instructions)
#   ...
#   '''
#   [claude] / [gemini] / [opencode] / [codex]
#   <field> = <value>                       harness-scoped fields, using each
#                                           harness's REAL field names (see the
#                                           defs/_template.*.toml for the full list)
#
# Supported TOML subset: "basic" and 'literal' strings, numbers, booleans,
# single-line arrays, ''' / """ multi-line strings whose closing delimiter sits on
# its own line, [section] headers, full-line # comments. NOT supported: inline
# tables, dotted keys, trailing comments after values, nested arrays — put anything
# fancier in a raw block.
#
# Special fields inside a harness table:
#   raw = '''...'''      verbatim lines injected into the generated file's metadata —
#                        YAML frontmatter for .md outputs, TOML for .toml outputs.
#                        Use for nested structures (opencode permission maps, claude
#                        hooks/mcpServers, extra codex tables).
#   body = '''...'''     replaces the shared body entirely for that harness.
#   emit = "skill"       [codex] on kind = "command": emit a Codex skill instead of
#                        a deprecated custom prompt.
#
# Portable body syntax, rewritten per harness:
#   $ARGUMENTS           command args (gemini: {{args}})
#   $1..$9               positional args, 1-based (claude output is shifted to its
#                        0-based convention automatically)
#   !`cmd`               inline shell where the harness supports it (gemini commands:
#                        !{cmd}); where it doesn't (codex, non-claude skills), it is
#                        rewritten to a bracketed run-this-command instruction.
#   <!-- only: h1, h2 --> ... <!-- /only -->   body section for listed harnesses only.
#
# Output goes under claude/ gemini/ opencode/ codex/ next to this script; generated
# files carry a GENERATED marker — edit the def, never the output.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFS_DIR="$ROOT/defs"
ALL_HARNESSES="claude gemini opencode codex"

usage() {
  cat <<'EOF'
Usage: ./transpile.sh [def-file ...]

With no arguments, transpiles every defs/*.toml except files starting with "_".
See the header comment in this script for the def language reference.
EOF
}

warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# --- def parsing ---------------------------------------------------------------
# Values land in FM: top-level keys as "key", section keys as "section.key".
# Arrays are stored comma-joined ("a, b"); list-shaped output fields re-split them.

declare -A FM
BODY=
CUR_DEF=

parse_scalar() {
  local val=$1
  if [[ ${#val} -ge 2 && $val == \"*\" ]]; then
    val=${val:1:${#val}-2}
    val=${val//\\\"/\"}
    val=${val//\\\\/\\}
  elif [[ ${#val} -ge 2 && $val == \'*\' ]]; then
    val=${val:1:${#val}-2}
  fi
  printf '%s' "$val"
}

parse_array() {
  local inner=$1 out= el
  inner=${inner:1:${#inner}-2}
  IFS=',' read -ra el <<<"$inner"
  local e
  for e in "${el[@]}"; do
    e=$(trim "$e")
    if [[ -z $e ]]; then continue; fi
    e=$(parse_scalar "$e")
    if [[ -n $out ]]; then out+=", "; fi
    out+=$e
  done
  printf '%s' "$out"
}

parse_def() {
  local file=$1 line tline key val fullkey section=
  local ml_key= ml_val= ml_delim=
  FM=()
  BODY=
  CUR_DEF=${file#"$ROOT"/}
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ -n $ml_key ]]; then
      if [[ $(trim "$line") == "$ml_delim" ]]; then
        FM[$ml_key]=$ml_val
        ml_key=
        ml_val=
        ml_delim=
      else
        ml_val+=$line$'\n'
      fi
      continue
    fi
    tline=$(trim "$line")
    if [[ -z $tline || $tline == \#* ]]; then continue; fi
    if [[ $tline == \[*\] ]]; then
      section=$(trim "${tline:1:${#tline}-2}")
      case $section in
        claude|gemini|opencode|codex) ;;
        *) die "$CUR_DEF: unknown section [$section] (expected claude, gemini, opencode, or codex)" ;;
      esac
      continue
    fi
    if [[ $tline != *=* ]]; then
      die "$CUR_DEF: bad line (expected 'key = value' or '[section]'): $tline"
    fi
    key=$(trim "${tline%%=*}")
    val=$(trim "${tline#*=}")
    fullkey=$key
    if [[ -n $section ]]; then fullkey="$section.$key"; fi
    if [[ $val == "'''" || $val == '"""' ]]; then
      ml_key=$fullkey
      ml_delim=$val
      ml_val=
      continue
    fi
    if [[ $val == \[*\] ]]; then
      FM[$fullkey]=$(parse_array "$val")
    else
      FM[$fullkey]=$(parse_scalar "$val")
    fi
  done <"$file"
  if [[ -n $ml_key ]]; then
    die "$CUR_DEF: unterminated multi-line string for '$ml_key'"
  fi
  BODY=${FM[body]:-}
  while [[ $BODY == $'\n'* ]]; do BODY=${BODY#$'\n'}; done
}

# Scoped lookup with generic fallback — ONLY for genuinely portable fields.
get() {
  local h=$1 k=$2
  if [[ -n ${FM[$h.$k]:-} ]]; then
    printf '%s' "${FM[$h.$k]}"
  else
    printf '%s' "${FM[$k]:-}"
  fi
}

# Harness-table lookup only — for fields that are never portable (models, tools, ...).
get_scoped() { printf '%s' "${FM[$1.$2]:-}"; }

targets_of() {
  local raw t out=
  raw=${FM[targets]:-$ALL_HARNESSES}
  raw=${raw//,/ }
  for t in $raw; do
    case $t in
      claude|gemini|opencode|codex) out+="$t " ;;
      *) die "$CUR_DEF: unknown target '$t'" ;;
    esac
  done
  printf '%s' "$out"
}

# --- body pipeline ---------------------------------------------------------------

filter_body() {
  printf '%s' "$BODY" | awk -v h="$1" '
    /^[[:space:]]*<!-- only:/ {
      spec=$0
      sub(/^[[:space:]]*<!-- only:[[:space:]]*/, "", spec)
      sub(/[[:space:]]*-->.*$/, "", spec)
      gsub(/,/, " ", spec)
      keep=0
      n=split(spec, a, " ")
      for (i=1; i<=n; i++) if (a[i]==h) keep=1
      inonly=1; next
    }
    /^[[:space:]]*<!--[[:space:]]*\/only[[:space:]]*-->/ { inonly=0; keep=0; next }
    inonly && !keep { next }
    { print }
  '
}

# Claude counts positional args from $0; the canonical def language is 1-based.
shift_positionals_for_claude() {
  sed -e 's/\$1\b/$0/g' -e 's/\$2\b/$1/g' -e 's/\$3\b/$2/g' \
      -e 's/\$4\b/$3/g' -e 's/\$5\b/$4/g' -e 's/\$6\b/$5/g' \
      -e 's/\$7\b/$6/g' -e 's/\$8\b/$7/g' -e 's/\$9\b/$8/g'
}

# For harnesses with no inline-shell preprocessing: turn !`cmd` into an explicit
# instruction the model can act on instead of dead syntax.
shell_to_instruction() {
  sed -e 's/!`\([^`]*\)`/[run `\1` in the shell and use its output]/g'
}

# body_for <harness> <kind> — the fully resolved body for one output file.
body_for() {
  local h=$1 kind=$2 b
  if [[ -n ${FM[$h.body]:-} ]]; then
    b=${FM[$h.body]}
  else
    b=$(filter_body "$h")
    case "$h:$kind" in
      claude:command|claude:skill)
        b=$(printf '%s' "$b" | shift_positionals_for_claude) ;;
      gemini:command)
        b=$(printf '%s' "$b" | sed -e 's/\$ARGUMENTS/{{args}}/g' -e 's/!`\([^`]*\)`/!{\1}/g') ;;
      gemini:skill|opencode:skill|codex:skill|codex:command)
        b=$(printf '%s' "$b" | shell_to_instruction) ;;
    esac
  fi
  while [[ $b == *$'\n' ]]; do b=${b%$'\n'}; done
  printf '%s' "$b"
}

# --- output helpers ----------------------------------------------------------------

gen_marker() { printf '# GENERATED by transpile.sh from %s — edit the def, not this file.\n' "$CUR_DEF"; }

# YAML single-quoted scalar: safe for colons, #, etc.
yq_() { printf "'%s'" "${1//\'/\'\'}"; }

# TOML basic string.
tq_() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }

# TOML multi-line literal string (no escapes processed inside).
toml_body() {
  local body=$1
  if [[ $body == *"'''"* ]]; then
    die "$CUR_DEF: content contains ''' which cannot be embedded in a TOML literal string"
  fi
  printf "'''\n%s'''" "$body"
}

# emit_kv <file> <yaml-key> <value> — appends the pair if value is non-empty.
emit_kv() {
  local file=$1 key=$2 val=$3
  if [[ -z $val ]]; then return 0; fi
  while [[ $val == *$'\n' ]]; do val=${val%$'\n'}; done
  if [[ $val == *$'\n'* ]]; then
    printf '%s: |-\n' "$key" >>"$file"
    printf '%s\n' "$val" | sed 's/^/  /' >>"$file"
  elif [[ $val =~ ^-?[0-9]+(\.[0-9]+)?$ || $val == true || $val == false ]]; then
    printf '%s: %s\n' "$key" "$val" >>"$file"
  else
    printf '%s: %s\n' "$key" "$(yq_ "$val")" >>"$file"
  fi
}

# emit_yaml_list <file> <key> <comma-joined values>
emit_yaml_list() {
  local file=$1 key=$2 val=$3 el e
  if [[ -z $val ]]; then return 0; fi
  printf '%s:\n' "$key" >>"$file"
  IFS=',' read -ra el <<<"$val"
  for e in "${el[@]}"; do printf -- '  - %s\n' "$(trim "$e")" >>"$file"; done
}

# emit_yaml_fields <file> <harness> <field...> — one emit_kv per harness-table field.
emit_yaml_fields() {
  local file=$1 harness=$2 f
  shift 2
  for f in "$@"; do emit_kv "$file" "$f" "$(get_scoped "$harness" "$f")"; done
}

# emit_toml_kv <file> <toml-key> <value>
emit_toml_kv() {
  local file=$1 key=$2 val=$3
  if [[ -z $val ]]; then return 0; fi
  if [[ $val == *$'\n'* ]]; then
    printf '%s = %s\n' "$key" "$(toml_body "$val")" >>"$file"
  elif [[ $val =~ ^-?[0-9]+(\.[0-9]+)?$ || $val == true || $val == false ]]; then
    printf '%s = %s\n' "$key" "$val" >>"$file"
  else
    printf '%s = %s\n' "$key" "$(tq_ "$val")" >>"$file"
  fi
}

# emit_toml_list <file> <key> <comma-joined values>
emit_toml_list() {
  local file=$1 key=$2 val=$3 el e out=
  if [[ -z $val ]]; then return 0; fi
  IFS=',' read -ra el <<<"$val"
  for e in "${el[@]}"; do
    if [[ -n $out ]]; then out+=", "; fi
    out+=$(tq_ "$(trim "$e")")
  done
  printf '%s = [%s]\n' "$key" "$out" >>"$file"
}

# emit_raw <harness> <file> — verbatim metadata passthrough from [harness] raw.
emit_raw() {
  local raw=${FM[$1.raw]:-}
  if [[ -z $raw ]]; then return 0; fi
  [[ $raw == *$'\n' ]] || raw+=$'\n'
  printf '%s' "$raw" >>"$2"
}

emit_body() { printf -- '---\n\n%s\n' "$2" >>"$1"; }

wrote() { printf '  -> %s\n' "${1#"$ROOT"/}"; }

copy_skill_assets() {
  local dest=$1
  if [[ -d $DEFS_DIR/${FM[name]} ]]; then
    cp -R "$DEFS_DIR/${FM[name]}"/. "$dest"/
  fi
}

# --- field lists (every documented frontmatter/TOML field per harness) --------------

CLAUDE_SKILL_FIELDS=(argument-hint arguments when_to_use disable-model-invocation
  user-invocable allowed-tools disallowed-tools model effort context agent paths shell)
CLAUDE_AGENT_FIELDS=(tools disallowedTools model permissionMode memory background
  effort isolation color initialPrompt)
GEMINI_AGENT_FIELDS=(kind model temperature max_turns timeout_mins)
OPENCODE_AGENT_FIELDS=(model variant temperature top_p hidden disable color steps)
OPENCODE_COMMAND_FIELDS=(agent model variant subtask)
CODEX_AGENT_FIELDS=(model model_reasoning_effort sandbox_mode)

# --- skill emitters (shared agentskills.io format) ------------------------------------

emit_skill() {
  local harness=$1 dir out
  dir="$ROOT/$harness/skills/${FM[name]}"
  out="$dir/SKILL.md"
  mkdir -p "$dir"
  { echo '---'; gen_marker; echo "name: ${FM[name]}"; } >"$out"
  emit_kv "$out" description "$(get "$harness" description)"
  if [[ $harness == claude ]]; then
    emit_yaml_fields "$out" claude "${CLAUDE_SKILL_FIELDS[@]}"
  fi
  emit_raw "$harness" "$out"
  emit_body "$out" "$(body_for "$harness" skill)"
  copy_skill_assets "$dir"
  wrote "$out"
}

# --- agent emitters ---------------------------------------------------------------------

emit_agent_claude() {
  local out="$ROOT/claude/agents/${FM[name]}.md" v
  mkdir -p "${out%/*}"
  { echo '---'; gen_marker; echo "name: ${FM[name]}"; } >"$out"
  emit_kv "$out" description "$(get claude description)"
  emit_yaml_fields "$out" claude "${CLAUDE_AGENT_FIELDS[@]}"
  v=$(get_scoped claude maxTurns)
  if [[ -z $v ]]; then v=${FM[max_turns]:-}; fi
  emit_kv "$out" maxTurns "$v"
  emit_yaml_list "$out" skills "$(get_scoped claude skills)"
  emit_raw claude "$out"
  emit_body "$out" "$(body_for claude agent)"
  wrote "$out"
}

emit_agent_gemini() {
  local out="$ROOT/gemini/agents/${FM[name]}.md" f v
  mkdir -p "${out%/*}"
  { echo '---'; gen_marker; echo "name: ${FM[name]}"; } >"$out"
  emit_kv "$out" description "$(get gemini description)"
  for f in "${GEMINI_AGENT_FIELDS[@]}"; do
    v=$(get_scoped gemini "$f")
    # temperature and max_turns are portable — fall back to the top level.
    if [[ -z $v && ( $f == temperature || $f == max_turns ) ]]; then v=${FM[$f]:-}; fi
    emit_kv "$out" "$f" "$v"
  done
  emit_yaml_list "$out" tools "$(get_scoped gemini tools)"
  emit_raw gemini "$out"
  emit_body "$out" "$(body_for gemini agent)"
  wrote "$out"
}

emit_agent_opencode() {
  local out="$ROOT/opencode/agents/${FM[name]}.md" f v
  mkdir -p "${out%/*}"
  { echo '---'; gen_marker; } >"$out"
  emit_kv "$out" description "$(get opencode description)"
  emit_kv "$out" mode "$(get opencode mode)"
  for f in "${OPENCODE_AGENT_FIELDS[@]}"; do
    v=$(get_scoped opencode "$f")
    if [[ -z $v && $f == temperature ]]; then v=${FM[temperature]:-}; fi
    emit_kv "$out" "$f" "$v"
  done
  emit_raw opencode "$out"
  emit_body "$out" "$(body_for opencode agent)"
  wrote "$out"
}

emit_agent_codex() {
  local out="$ROOT/codex/agents/${FM[name]}.toml" f
  mkdir -p "${out%/*}"
  gen_marker >"$out"
  emit_toml_kv "$out" name "${FM[name]}"
  emit_toml_kv "$out" description "$(get codex description)"
  for f in "${CODEX_AGENT_FIELDS[@]}"; do
    emit_toml_kv "$out" "$f" "$(get_scoped codex "$f")"
  done
  emit_toml_list "$out" nickname_candidates "$(get_scoped codex nickname_candidates)"
  printf 'developer_instructions = %s\n' "$(toml_body "$(body_for codex agent)"$'\n')" >>"$out"
  emit_raw codex "$out"
  wrote "$out"
}

# --- command emitters ----------------------------------------------------------------------

emit_command_claude() {
  # Claude commands share the skill frontmatter (commands were merged into skills).
  local out="$ROOT/claude/commands/${FM[name]}.md"
  mkdir -p "${out%/*}"
  { echo '---'; gen_marker; } >"$out"
  emit_kv "$out" description "$(get claude description)"
  emit_yaml_fields "$out" claude "${CLAUDE_SKILL_FIELDS[@]}"
  emit_raw claude "$out"
  emit_body "$out" "$(body_for claude command)"
  wrote "$out"
}

emit_command_gemini() {
  local out="$ROOT/gemini/commands/${FM[name]}.toml"
  mkdir -p "${out%/*}"
  gen_marker >"$out"
  emit_toml_kv "$out" description "$(get gemini description)"
  printf 'prompt = %s\n' "$(toml_body "$(body_for gemini command)"$'\n')" >>"$out"
  emit_raw gemini "$out"
  wrote "$out"
}

emit_command_opencode() {
  local out="$ROOT/opencode/commands/${FM[name]}.md" f
  mkdir -p "${out%/*}"
  { echo '---'; gen_marker; } >"$out"
  emit_kv "$out" description "$(get opencode description)"
  for f in "${OPENCODE_COMMAND_FIELDS[@]}"; do
    emit_kv "$out" "$f" "$(get_scoped opencode "$f")"
  done
  emit_raw opencode "$out"
  emit_body "$out" "$(body_for opencode command)"
  wrote "$out"
}

emit_command_codex() {
  # Codex custom prompts are deprecated but remain its command-shaped artifact;
  # invoked as /prompts:<name>. Set emit = "skill" in [codex] to ship a skill instead.
  local out="$ROOT/codex/prompts/${FM[name]}.md"
  mkdir -p "${out%/*}"
  { echo '---'; gen_marker; } >"$out"
  emit_kv "$out" description "$(get codex description)"
  emit_kv "$out" argument-hint "$(get_scoped codex argument-hint)"
  emit_raw codex "$out"
  emit_body "$out" "$(body_for codex command)"
  wrote "$out"
}

# --- driver -----------------------------------------------------------------------------------

build_def() {
  local file=$1 kind name t
  parse_def "$file"
  kind=${FM[kind]:-}
  name=${FM[name]:-}
  if [[ -z $kind ]]; then die "$CUR_DEF: missing 'kind'"; fi
  if [[ -z $name ]]; then die "$CUR_DEF: missing 'name'"; fi
  case $kind in
    skill|agent|command) ;;
    *) die "$CUR_DEF: unknown kind '$kind' (expected skill, agent, or command)" ;;
  esac
  if [[ ! $name =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    warn "$CUR_DEF: name '$name' is not lowercase-hyphen; some harnesses may reject it"
  fi
  if [[ -z ${FM[description]:-} ]]; then
    warn "$CUR_DEF: missing 'description'"
  fi
  if [[ -z $BODY ]]; then
    warn "$CUR_DEF: empty 'body'"
  fi
  if [[ $BODY =~ \$0 ]]; then
    warn "$CUR_DEF: \$0 found — canonical positional args are 1-based (\$1 is first); claude output is shifted automatically"
  fi
  if [[ $kind == agent && $BODY == *'!`'* ]]; then
    warn "$CUR_DEF: !\`cmd\` in an agent body — agent system prompts are never shell-preprocessed in any harness"
  fi
  if [[ $kind == agent && -z ${FM[mode]:-}${FM[opencode.mode]:-} ]]; then
    FM[mode]=subagent
  fi

  printf '%s (%s):\n' "$CUR_DEF" "$kind"
  for t in $(targets_of); do
    case "$kind:$t" in
      skill:*)          emit_skill "$t" ;;
      agent:claude)     emit_agent_claude ;;
      agent:gemini)     emit_agent_gemini ;;
      agent:opencode)   emit_agent_opencode ;;
      agent:codex)      emit_agent_codex ;;
      command:claude)   emit_command_claude ;;
      command:gemini)   emit_command_gemini ;;
      command:opencode) emit_command_opencode ;;
      command:codex)
        if [[ $(get_scoped codex emit) == skill ]]; then
          emit_skill codex
        else
          emit_command_codex
        fi ;;
    esac
  done
}

main() {
  local files=() f
  if (( $# )); then
    case $1 in -h|--help) usage; exit 0 ;; esac
    files=("$@")
  else
    if [[ ! -d $DEFS_DIR ]]; then die "no defs/ directory at $DEFS_DIR"; fi
    for f in "$DEFS_DIR"/*.toml; do
      if [[ ! -e $f ]]; then die "no .toml defs found in $DEFS_DIR"; fi
      if [[ $(basename "$f") == _* ]]; then continue; fi
      files+=("$f")
    done
    if (( ${#files[@]} == 0 )); then
      die "defs/ contains only _-prefixed templates; copy one to defs/<name>.<kind>.toml first"
    fi
  fi
  for f in "${files[@]}"; do
    if [[ ! -f $f ]]; then die "no such file: $f"; fi
    build_def "$f"
  done
}

main "$@"
