#!/usr/bin/env bash
# transpile.sh — build harness-native agents/skills/commands from unified TOML defs.
#
# Source language: defs/<name>.<kind>.toml — a TOML subset. The artifact's name
# and kind come from the file name itself; kind = / name = keys override them
# (needed when the file name doesn't follow the <name>.<kind>.toml pattern).
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
# single-line arrays, ''' / """ multi-line strings (inline '''x''' works; for
# multi-line values text may follow the opening delimiter and the closing delimiter
# starts its own line), [section] headers, # comments (full-line or trailing).
# NOT supported: inline tables, dotted keys, nested arrays — put anything fancier
# in a raw block. Multi-line values are dedented by the whitespace prefix common
# to all non-empty lines, so uncommented indented template blocks emit flush-left.
# Anything unparseable is a hard error — the build never emits a mangled value.
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
# Output goes under claude/ gemini/ opencode/ codex/ next to this script — those
# directories are pure build output; edit the def, never the output.
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
# Arrays are stored SEP-joined so elements may contain commas; list-shaped output
# fields re-split them (falling back to commas for plain-string values).

SEP=$'\x1f'

declare -A FM
BODY=
CUR_DEF=
CUR_LINENO=0

perr() { die "$CUR_DEF:$CUR_LINENO: $*"; }

# After a parsed value, only whitespace or a # comment may remain on the line.
check_tail() {
  local rest
  rest=$(trim "$1")
  if [[ -n $rest && $rest != \#* ]]; then
    perr "unexpected content after value: $rest"
  fi
}

# Strip the shortest leading whitespace found on any non-empty line from all lines,
# so an indented block (e.g. an uncommented template raw = '''...''') emits flush-left.
dedent() {
  printf '%s' "$1" | awk '
    { lines[NR] = $0 }
    /[^ \t]/ { match($0, /^[ \t]*/); if (!seen || RLENGTH < min) { min = RLENGTH; seen = 1 } }
    END { if (!seen) min = 0; for (i = 1; i <= NR; i++) print substr(lines[i], min + 1) }'
}

# scan_literal_string / scan_basic_string: parse a quoted token at the start of $1.
# Set SCAN_VAL to the contents and SCAN_TAIL to everything after the closing quote.
SCAN_VAL= SCAN_TAIL=
scan_literal_string() {
  local rest=${1:1}
  if [[ $rest != *\'* ]]; then perr "unterminated string: $1"; fi
  SCAN_VAL=${rest%%\'*}
  SCAN_TAIL=${rest#*\'}
}

scan_basic_string() {
  local s=$1 i=1 c nx out= n
  n=${#s}
  while (( i < n )); do
    c=${s:i:1}
    if [[ $c == \\ ]]; then
      nx=${s:i+1:1}
      case $nx in
        '"') out+='"' ;;
        \\)  out+='\' ;;
        n)   out+=$'\n' ;;
        t)   out+=$'\t' ;;
        *)   out+="\\$nx" ;;
      esac
      i=$((i + 2))
      continue
    fi
    if [[ $c == '"' ]]; then
      SCAN_VAL=$out
      SCAN_TAIL=${s:i+1}
      return 0
    fi
    out+=$c
    i=$((i + 1))
  done
  perr "unterminated string: $s"
}

# parse_array: a [...] token at the start of $1. Quoted elements may contain
# commas, # and ]. Sets SCAN_VAL to the comma-joined parsed elements and
# SCAN_TAIL to everything after the closing bracket.
parse_array() {
  local s=${1:1} out= closed=0 e
  while :; do
    s=${s#"${s%%[![:space:]]*}"}
    if [[ -z $s ]]; then break; fi
    case $s in
      ']'*) closed=1; SCAN_TAIL=${s:1}; break ;;
      ','*) s=${s:1}; continue ;;
      \'*)  scan_literal_string "$s"; s=$SCAN_TAIL ;;
      \"*)  scan_basic_string "$s"; s=$SCAN_TAIL ;;
      *)
        e=${s%%[],]*}
        if [[ $e == "$s" ]]; then break; fi
        s=${s:${#e}}
        e=$(trim "$e")
        if [[ ! ( $e =~ ^-?[0-9]+(\.[0-9]+)?$ || $e == true || $e == false ) ]]; then
          perr "bad array element '$e' (strings must be quoted)"
        fi
        SCAN_VAL=$e ;;
    esac
    if [[ -n $out ]]; then out+=$SEP; fi
    out+=$SCAN_VAL
  done
  if (( ! closed )); then perr "unterminated array: $1"; fi
  SCAN_VAL=$out
}

# parse_value <rhs>: sets PV_VAL, or PV_ML=1 with PV_DELIM/PV_SEED when the value
# opens a multi-line string that continues on following lines.
PV_VAL= PV_ML=0 PV_DELIM= PV_SEED=
parse_value() {
  local val=$1 delim rest
  PV_VAL= PV_ML=0 PV_DELIM= PV_SEED=
  case $val in
    "'''"*|'"""'*)
      delim=${val:0:3}
      rest=${val:3}
      if [[ $rest == *"$delim"* ]]; then
        PV_VAL=${rest%%"$delim"*}
        check_tail "${rest#*"$delim"}"
      else
        PV_ML=1 PV_DELIM=$delim PV_SEED=$rest
      fi ;;
    \'*)
      scan_literal_string "$val"
      PV_VAL=$SCAN_VAL
      check_tail "$SCAN_TAIL" ;;
    \"*)
      scan_basic_string "$val"
      PV_VAL=$SCAN_VAL
      check_tail "$SCAN_TAIL" ;;
    \[*)
      parse_array "$val"
      PV_VAL=$SCAN_VAL
      check_tail "$SCAN_TAIL" ;;
    *)
      rest=${val%%#*}
      rest=$(trim "$rest")
      if [[ -z $rest ]]; then
        perr "missing value"
      fi
      if [[ ! ( $rest =~ ^-?[0-9]+(\.[0-9]+)?$ || $rest == true || $rest == false ) ]]; then
        perr "unquoted value '$rest' (strings must be quoted)"
      fi
      PV_VAL=$rest ;;
  esac
}

parse_def() {
  local file=$1 line tline key val fullkey section=
  local ml_key= ml_val= ml_delim=
  FM=()
  BODY=
  CUR_DEF=${file#"$ROOT"/}
  CUR_LINENO=0
  while IFS= read -r line || [[ -n $line ]]; do
    CUR_LINENO=$((CUR_LINENO + 1))
    if [[ -n $ml_key ]]; then
      tline=$(trim "$line")
      if [[ $tline == "$ml_delim"* ]]; then
        check_tail "${tline#"$ml_delim"}"
        FM[$ml_key]=$(dedent "$ml_val")
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
        *) perr "unknown section [$section] (expected claude, gemini, opencode, or codex)" ;;
      esac
      continue
    fi
    if [[ $tline != *=* ]]; then
      perr "bad line (expected 'key = value' or '[section]'): $tline"
    fi
    key=$(trim "${tline%%=*}")
    val=$(trim "${tline#*=}")
    if [[ -z $key ]]; then perr "missing key: $tline"; fi
    fullkey=$key
    if [[ -n $section ]]; then fullkey="$section.$key"; fi
    parse_value "$val"
    if (( PV_ML )); then
      ml_key=$fullkey
      ml_delim=$PV_DELIM
      ml_val=$PV_SEED
      if [[ -n $ml_val ]]; then ml_val+=$'\n'; fi
      continue
    fi
    FM[$fullkey]=$PV_VAL
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
  raw=${raw//$SEP/ }
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

# yaml_scalar <value> — typed YAML scalar: bare numbers/booleans, quoted otherwise.
yaml_scalar() {
  if [[ $1 =~ ^-?[0-9]+(\.[0-9]+)?$ || $1 == true || $1 == false ]]; then
    printf '%s' "$1"
  else
    yq_ "$1"
  fi
}

# split_list <value> — one element per line; splits arrays on SEP, plain strings on commas.
split_list() {
  local val=$1 el e
  if [[ $val == *"$SEP"* ]]; then
    IFS=$SEP read -ra el <<<"$val"
  else
    IFS=',' read -ra el <<<"$val"
  fi
  for e in "${el[@]}"; do printf '%s\n' "$(trim "$e")"; done
}

# emit_kv <file> <yaml-key> <value> — appends the pair if value is non-empty.
emit_kv() {
  local file=$1 key=$2 val=$3
  if [[ -z $val ]]; then return 0; fi
  val=${val//$SEP/, }  # array used where the harness expects a scalar: comma-join
  while [[ $val == *$'\n' ]]; do val=${val%$'\n'}; done
  if [[ $val == *$'\n'* ]]; then
    printf '%s: |-\n' "$key" >>"$file"
    printf '%s\n' "$val" | sed 's/^/  /' >>"$file"
  else
    printf '%s: %s\n' "$key" "$(yaml_scalar "$val")" >>"$file"
  fi
}

# emit_yaml_list <file> <key> <SEP- or comma-joined values>
emit_yaml_list() {
  local file=$1 key=$2 val=$3 e
  if [[ -z $val ]]; then return 0; fi
  printf '%s:\n' "$key" >>"$file"
  while IFS= read -r e; do
    printf -- '  - %s\n' "$(yaml_scalar "$e")" >>"$file"
  done < <(split_list "$val")
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
  val=${val//$SEP/, }
  if [[ $val == *$'\n'* ]]; then
    printf '%s = %s\n' "$key" "$(toml_body "$val")" >>"$file"
  elif [[ $val =~ ^-?[0-9]+(\.[0-9]+)?$ || $val == true || $val == false ]]; then
    printf '%s = %s\n' "$key" "$val" >>"$file"
  else
    printf '%s = %s\n' "$key" "$(tq_ "$val")" >>"$file"
  fi
}

# emit_toml_list <file> <key> <SEP- or comma-joined values>
emit_toml_list() {
  local file=$1 key=$2 val=$3 e out=
  if [[ -z $val ]]; then return 0; fi
  while IFS= read -r e; do
    if [[ -n $out ]]; then out+=", "; fi
    out+=$(tq_ "$e")
  done < <(split_list "$val")
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

# arguments is list-shaped and emitted separately via emit_yaml_list.
CLAUDE_SKILL_FIELDS=(argument-hint when_to_use disable-model-invocation
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
  { echo '---'; echo "name: ${FM[name]}"; } >"$out"
  emit_kv "$out" description "$(get "$harness" description)"
  if [[ $harness == claude ]]; then
    emit_yaml_fields "$out" claude "${CLAUDE_SKILL_FIELDS[@]}"
    emit_yaml_list "$out" arguments "$(get_scoped claude arguments)"
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
  { echo '---'; echo "name: ${FM[name]}"; } >"$out"
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
  { echo '---'; echo "name: ${FM[name]}"; } >"$out"
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
  echo '---' >"$out"
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
  : >"$out"
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
  echo '---' >"$out"
  emit_kv "$out" description "$(get claude description)"
  emit_yaml_fields "$out" claude "${CLAUDE_SKILL_FIELDS[@]}"
  emit_yaml_list "$out" arguments "$(get_scoped claude arguments)"
  emit_raw claude "$out"
  emit_body "$out" "$(body_for claude command)"
  wrote "$out"
}

emit_command_gemini() {
  local out="$ROOT/gemini/commands/${FM[name]}.toml"
  mkdir -p "${out%/*}"
  : >"$out"
  emit_toml_kv "$out" description "$(get gemini description)"
  printf 'prompt = %s\n' "$(toml_body "$(body_for gemini command)"$'\n')" >>"$out"
  emit_raw gemini "$out"
  wrote "$out"
}

emit_command_opencode() {
  local out="$ROOT/opencode/commands/${FM[name]}.md" f
  mkdir -p "${out%/*}"
  echo '---' >"$out"
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
  echo '---' >"$out"
  emit_kv "$out" description "$(get codex description)"
  emit_kv "$out" argument-hint "$(get_scoped codex argument-hint)"
  emit_raw codex "$out"
  emit_body "$out" "$(body_for codex command)"
  wrote "$out"
}

# --- driver -----------------------------------------------------------------------------------

build_def() {
  local file=$1 kind name base t
  parse_def "$file"
  # name and kind come from the file name (defs/<name>.<kind>.toml);
  # explicit kind = / name = keys in the def override them.
  base=$(basename "$file" .toml)
  kind=${FM[kind]:-}
  name=${FM[name]:-}
  case $base in
    *.agent)   kind=${kind:-agent};   name=${name:-${base%.agent}} ;;
    *.skill)   kind=${kind:-skill};   name=${name:-${base%.skill}} ;;
    *.command) kind=${kind:-command}; name=${name:-${base%.command}} ;;
    *)         name=${name:-$base} ;;
  esac
  if [[ -z $kind ]]; then
    die "$CUR_DEF: cannot infer kind — name the file <name>.<kind>.toml or set kind = \"skill|agent|command\""
  fi
  case $kind in
    skill|agent|command) ;;
    *) die "$CUR_DEF: unknown kind '$kind' (expected skill, agent, or command)" ;;
  esac
  FM[name]=$name
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
