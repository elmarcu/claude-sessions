#!/usr/bin/env bash
# List Claude Code sessions for a project, title/content filter/search, then open (resume), clone or delete them.
# Requires: bash 3.2+, jq. Optional: rg (faster content search). Runs on macOS and Linux.
set -u

PROJECTS_ROOT="$HOME/.claude/projects"

# GNU (Linux) and BSD (macOS) stat/date take different flags; pick once.
if stat -c %Y / >/dev/null 2>&1; then
  file_mtime_size() { stat -c '%Y %s' "$1"; }
else
  file_mtime_size() { stat -f '%m %z' "$1"; }
fi
if date -d @0 >/dev/null 2>&1; then
  fmt_time() { date -d "@$1" '+%b %d %H:%M'; }
else
  fmt_time() { date -r "$1" '+%b %d %H:%M'; }
fi

new_uuid() {
  if command -v uuidgen >/dev/null; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    return 1
  fi
}

# How long to wait after Esc for the rest of an arrow-key sequence. bash 3.2
# (macOS default) only takes whole seconds, so a bare Esc lags there.
ESC_TIMEOUT=1
((BASH_VERSINFO[0] >= 4)) && ESC_TIMEOUT=0.05

has_sessions() { compgen -G "$1/*.jsonl" >/dev/null; }

# Sets PROJECT_DIR from, in order: the argument, the current folder if it holds
# sessions, the Claude project for the current folder, or a pick from all projects.
resolve_project_dir() {
  local arg="${1:-}" d n i ans
  local -a dirs
  if [ -n "$arg" ]; then
    PROJECT_DIR="${arg/#\~/$HOME}"
    [ -d "$PROJECT_DIR" ] || { echo "Not a directory: $PROJECT_DIR"; exit 1; }
    return
  fi
  if has_sessions "$PWD"; then
    PROJECT_DIR="$PWD"
    return
  fi
  # Claude Code names a project's folder after its path, with non-alphanumerics as '-'.
  PROJECT_DIR="$PROJECTS_ROOT/$(printf '%s' "$PWD" | sed 's/[^A-Za-z0-9]/-/g')"
  has_sessions "$PROJECT_DIR" && return
  dirs=()
  while IFS= read -r d; do
    has_sessions "$d" && dirs+=("${d%/}")
  done < <(ls -td "$PROJECTS_ROOT"/*/ 2>/dev/null)
  [ ${#dirs[@]} -gt 0 ] || { echo "No Claude sessions found in $PROJECTS_ROOT"; exit 1; }
  echo "No sessions for $PWD. Pick a project:"
  for ((i = 0; i < ${#dirs[@]}; i++)); do
    n=$(ls "${dirs[i]}"/*.jsonl | wc -l | xargs)
    printf "%2d) %s (%s sessions)\n" $((i + 1)) "$(basename "${dirs[i]}")" "$n"
  done
  read -r -p "> " ans || exit 1
  [[ $ans =~ ^[0-9]+$ ]] && ((ans >= 1 && ans <= ${#dirs[@]})) || { echo "Invalid choice"; exit 1; }
  PROJECT_DIR="${dirs[ans - 1]}"
}

# Prints "<cwd>\t<branch>\t<turns>\t<title>" for one session file ('-' for empty fields,
# since read with a tab IFS collapses empty columns).
# Title: last custom-title, else Claude's generated ai-title, else first summary /
# plain-text user message.
# Turns: user messages you typed (not tool results or system-injected text).
read_session() {
  jq -Rrn '
    [inputs | fromjson? | objects] as $l
    | ([$l[] | .cwd // empty | select(. != "")] | first // "-") as $cwd
    | ([$l[] | .gitBranch // empty | select(. != "" and . != "HEAD")] | last // "-") as $branch
    | ([$l[] | select(.type == "user")
        | (.message.content? // "")
        | if type == "array" then (map(select(.type == "text") | .text // "") | first // "")
          elif type == "string" then .
          else "" end
        | select(. != "" and (startswith("<") | not))] | length) as $turns
    | ([$l[] | select(.type == "custom-title") | .customTitle // empty | select(. != "")] | last) as $custom
    | ([$l[] | select(.type == "ai-title") | .aiTitle // empty | select(. != "")] | last) as $ai
    | ([$l[]
        | if .type == "summary" then .summary // ""
          elif .type == "user" then
            (.message.content? // "")
            | if type == "array" then (map(select(.type == "text") | .text // "") | first // "")
              elif type == "string" then .
              else "" end
            | if startswith("<") then "" else (gsub("^\\s+|\\s+$"; "") | gsub("\n"; " ") | .[:60]) end
          else empty end
        | select(. != "")] | first) as $first
    | "\($cwd)\t\($branch)\t\($turns)\t\(($custom // $ai // $first // "(no title)") | gsub("\t"; " "))"
  ' "$1" 2>/dev/null
}

# Per-session columns, kept as parallel arrays.
FIELDS="FILES UIDS MTIMES SIZES TITLES CWDS BRANCHES TURNS SNIPPETS"

load_sessions() {
  FILES=() UIDS=() MTIMES=() SIZES=() TITLES=() CWDS=() BRANCHES=() TURNS=() SNIPPETS=()
  local f cwd branch turns title mtime size
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    IFS=$'\t' read -r cwd branch turns title < <(read_session "$f")
    read -r mtime size < <(file_mtime_size "$f")
    FILES+=("$f")
    UIDS+=("$(basename "$f" .jsonl)")
    MTIMES+=("$(fmt_time "$mtime")")
    SIZES+=("$(( size / 1024 ))K")
    TITLES+=("${title:-(no title)}")
    [ "$cwd" = "-" ] && cwd=""
    CWDS+=("$cwd")
    BRANCHES+=("${branch:--}")
    TURNS+=("${turns:-0}")
    SNIPPETS+=("")
  done < <(ls -t "$PROJECT_DIR"/*.jsonl 2>/dev/null)
}

# Prints "<file>:<first matching line>" for each file containing $1 (fixed string,
# case-insensitive). Uses ripgrep when installed (searches files in parallel).
first_matches() {
  local q=$1; shift
  if command -v rg >/dev/null; then
    rg -iF -m1 --with-filename --no-line-number --no-heading --no-messages -e "$q" -- "$@"
  else
    grep -iF -m1 -H -e "$q" -- "$@" 2>/dev/null
  fi
}

# Keeps only sessions matching FILTER (case-insensitive): by title, or anywhere
# in the session file when SEARCH_MODE is "content". Content matches also fill
# SNIPPETS with the text around the first hit, the match highlighted.
apply_filter() {
  [ -z "$FILTER" ] && return
  local i a f snip esc hits=""
  local -a keep=() tmp
  if [ "$SEARCH_MODE" = content ]; then
    # Session files are JSON, so search for the query as it's stored there
    # (a typed \ is written as \\, a " as \").
    esc="$(printf '%s' "$FILTER" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    # First matching line per file, then cut the snippet in awk (a context regex
    # like '.{0,30}q.{0,30}' is very slow in BSD grep).
    hits="$(first_matches "$esc" "${FILES[@]}" | Q="$FILTER" E="$esc" awk '
      BEGIN { q = ENVIRON["Q"]; e = ENVIRON["E"] }
      {
        k = index($0, ".jsonl:"); if (!k) next
        f = substr($0, 1, k + 5); s = substr($0, k + 7)
        if (f in seen) next; seen[f] = 1
        p = index(tolower(s), tolower(e)); if (!p) next
        st = p > 30 ? p - 30 : 1
        s = substr(s, st, p - st + length(e) + 30)
        # Undo JSON escapes so the snippet reads like the original text:
        # \n \r \t become spaces, any other \x becomes x.
        out = ""
        for (i = 1; i <= length(s); i++) {
          c = substr(s, i, 1)
          if (c == "\\" && i < length(s)) {
            d = substr(s, ++i, 1)
            out = out ((d == "n" || d == "r" || d == "t") ? " " : d)
          } else out = out (c == "\t" ? " " : c)
        }
        s = out
        p = index(tolower(s), tolower(q))
        if (p) s = substr(s, 1, p - 1) "\033[1;33m" substr(s, p, length(q)) "\033[0m" substr(s, p + length(q))
        print f "\t" s
      }')"
    # Walk the list in its own order (newest first); rg returns files in any order.
    hits=$'\n'"$hits"$'\n'
    for ((i = 0; i < ${#FILES[@]}; i++)); do
      f=$'\n'"${FILES[i]}"$'\t'
      [[ $hits == *"$f"* ]] || continue
      snip="${hits#*"$f"}"
      SNIPPETS[i]="${snip%%$'\n'*}"
      keep+=("$i")
    done
  else
    shopt -s nocasematch
    for ((i = 0; i < ${#UIDS[@]}; i++)); do
      [[ ${TITLES[i]} == *"$FILTER"* ]] && keep+=("$i")
    done
    shopt -u nocasematch
  fi
  for a in $FIELDS; do
    tmp=()
    for i in ${keep[@]+"${keep[@]}"}; do eval "tmp+=(\"\${$a[i]}\")"; done
    eval "$a=(\${tmp[@]+\"\${tmp[@]}\"})"
  done
}

# Snapshot of the full list, so each keystroke re-filters without re-reading files.
cache_sessions() {
  local a
  for a in $FIELDS; do eval "A_$a=(\"\${$a[@]}\")"; done
}

restore_sessions() {
  local a
  for a in $FIELDS; do eval "$a=(\"\${A_$a[@]}\")"; done
}

# Columns: modified | size | turns | git branch | short id | title.
# Short IDs work in commands too (prefix match).
print_sessions() {
  local n=${#UIDS[@]} i
  local w=${#n}
  if [ "$SEARCH_MODE" = content ] && [ -n "$FILTER" ]; then
    # Content matches: shorter title, plus the text found.
    printf "%${w}s  %-12s | %6s | %4s | %-18s | %-8s | %-30s | %s\n" "#" "MODIFIED" "SIZE" "MSGS" "BRANCH" "ID" "TITLE" "MATCH"
    for ((i = 0; i < n; i++)); do
      printf "%${w}d) %s | %6s | %4s | %-18.18s | %.8s | %-30.30s | %s\n" $((i + 1)) "${MTIMES[i]}" "${SIZES[i]}" \
        "${TURNS[i]}" "${BRANCHES[i]}" "${UIDS[i]}" "${TITLES[i]}" "${SNIPPETS[i]}"
    done
    return
  fi
  printf "%${w}s  %-12s | %6s | %4s | %-18s | %-8s | %s\n" "#" "MODIFIED" "SIZE" "MSGS" "BRANCH" "ID" "TITLE"
  for ((i = 0; i < n; i++)); do
    printf "%${w}d) %s | %6s | %4s | %-18.18s | %.8s | %s\n" $((i + 1)) "${MTIMES[i]}" "${SIZES[i]}" \
      "${TURNS[i]}" "${BRANCHES[i]}" "${UIDS[i]}" "${TITLES[i]}"
  done
}

# Accepts list numbers ('3', '1,4', '2-5') or full/prefix session IDs.
# Sets SELECTED to the matching 0-based indexes (deduped). Returns 1 on error.
parse_selection() {
  SELECTED=()
  local n=${#UIDS[@]} tok a b i idx hits
  local -a idxs
  for tok in ${1//,/ }; do
    idxs=()
    if [[ $tok =~ ^([0-9]+)-([0-9]+)$ ]]; then
      a=${BASH_REMATCH[1]} b=${BASH_REMATCH[2]}
      ((a > b)) && { i=$a; a=$b; b=$i; }
      for ((i = a; i <= b; i++)); do idxs+=($((i - 1))); done
    elif [[ $tok =~ ^[0-9]+$ ]]; then
      idxs=($((tok - 1)))
    else
      hits=()
      for ((i = 0; i < n; i++)); do [[ ${UIDS[i]} == "$tok"* ]] && hits+=("$i"); done
      if [ ${#hits[@]} -ne 1 ]; then
        echo "Error: '$tok' matches ${#hits[@]} sessions"
        return 1
      fi
      idxs=("${hits[0]}")
    fi
    for idx in "${idxs[@]}"; do
      if ((idx < 0 || idx >= n)); then
        echo "Error: no session #$((idx + 1))"
        return 1
      fi
      [[ " ${SELECTED[*]-} " == *" $idx "* ]] || SELECTED+=("$idx")
    done
  done
}

# Runs claude in a subshell so the script's list comes back when it exits.
# Returns 1 if claude couldn't be started.
open_session() {
  local i=$1
  command -v claude >/dev/null || { echo '`claude` not found on PATH'; return 1; }
  (
    # Sessions are scoped per project, so resume from the directory they were started in.
    [ -n "${CWDS[i]}" ] && [ -d "${CWDS[i]}" ] && cd "${CWDS[i]}"
    echo "Resuming ${UIDS[i]} in $PWD ..."
    claude --resume "${UIDS[i]}"
  )
}

delete_sessions() {
  local i ans
  for i in "${SELECTED[@]}"; do echo "  ${UIDS[i]} | ${TITLES[i]}"; done
  read -r -p "Delete ${#SELECTED[@]} session(s) from disk? [y/N] " ans
  [[ $ans == [yY] ]] || { echo "Cancelled."; return; }
  for i in "${SELECTED[@]}"; do
    rm -f "${FILES[i]}"
    # Side folder with subagent transcripts / tool results, if present.
    [ -d "$PROJECT_DIR/${UIDS[i]}" ] && rm -rf "${PROJECT_DIR:?}/${UIDS[i]}"
    echo "Deleted ${UIDS[i]}"
  done
}

# Copies each selected session under a new ID, titled "<title>_forked".
clone_sessions() {
  local i new title
  for i in "${SELECTED[@]}"; do
    new="$(new_uuid)" || { echo "Can't generate a session ID (install uuidgen)"; return; }
    title="${TITLES[i]}"
    [ "$title" = "(no title)" ] && title="${UIDS[i]}"
    title="${title}_forked"
    # Every line carries the session ID; rewrite it so the copy is its own session.
    sed "s/${UIDS[i]}/$new/g" "${FILES[i]}" > "$PROJECT_DIR/$new.jsonl" || { echo "Failed to clone ${UIDS[i]}"; continue; }
    jq -nc --arg t "$title" --arg s "$new" '{type: "custom-title", customTitle: $t, sessionId: $s}' >> "$PROJECT_DIR/$new.jsonl"
    if [ -d "$PROJECT_DIR/${UIDS[i]}" ]; then
      cp -R "$PROJECT_DIR/${UIDS[i]}" "$PROJECT_DIR/$new"
    fi
    echo "Cloned ${UIDS[i]} -> $new | $title"
  done
}

# Reads and runs one command against the current (filtered) list. Returns 1 to quit.
run_command() {
  local cmd
  read -e -r -p "<n|id> open · c <n,n-m|id...> clone · d <n,n-m|id...> delete · q quit > " cmd || return 1
  cmd="$(echo "$cmd" | xargs)"
  [ -z "$cmd" ] && return 0
  case "$(echo "$cmd" | tr '[:upper:]' '[:lower:]')" in
    q | quit | exit) return 1 ;;
    "d "*)
      parse_selection "${cmd:2}" && delete_sessions ;;
    "c "*)
      parse_selection "${cmd:2}" && clone_sessions ;;
    *)
      if parse_selection "$cmd"; then
        if [ ${#SELECTED[@]} -ne 1 ]; then
          echo "Pick exactly one session to open."
        else
          open_session "${SELECTED[0]}" && return 0
        fi
      fi ;;
  esac
  read -rsn1 -p "Press any key to continue..." _
}

# Typing filters the list by title live; '/' opens the command prompt.
main() {
  command -v jq >/dev/null || { echo "jq is required (macOS: brew install jq · Debian/Ubuntu: sudo apt install jq)"; exit 1; }
  resolve_project_dir "$@"
  local key rest rows reload=1
  FILTER="" SEARCH_MODE=title
  while true; do
    if ((reload)); then
      load_sessions
      if [ ${#UIDS[@]} -eq 0 ]; then
        echo "No sessions in $PROJECT_DIR"
        return
      fi
      cache_sessions
      reload=0
    fi
    restore_sessions
    apply_filter
    rows=$(( $(tput lines 2>/dev/null || echo 24) - 5 ))
    printf '\033[H\033[2J'
    print_sessions | head -n "$rows"
    [ ${#UIDS[@]} -eq 0 ] && echo "(no matches)"
    echo
    echo "Type to filter · Tab title/content · Enter open first · Backspace edit · Ctrl-U/Esc clear · / commands"
    printf 'Filter [%s]: %s' "$SEARCH_MODE" "$FILTER"
    IFS= read -rsn1 key || { echo; return; }
    case "$key" in
      '')
        # Enter opens the top session of the (filtered) list.
        if [ ${#UIDS[@]} -gt 0 ]; then
          echo
          open_session 0 || read -rsn1 -p "Press any key to continue..." _
          reload=1
        fi ;;
      /)
        echo
        run_command || return
        reload=1 ;;
      $'\t')
        if [ "$SEARCH_MODE" = title ]; then SEARCH_MODE=content; else SEARCH_MODE=title; fi ;;
      $'\x7f' | $'\b') FILTER="${FILTER%?}" ;;
      $'\x15') FILTER="" ;;
      $'\e')
        # Arrow keys send ESC + 2 bytes at once; a bare Esc times out and clears.
        IFS= read -rsn2 -t "$ESC_TIMEOUT" rest || FILTER="" ;;
      ' ') [ -n "$FILTER" ] && FILTER+=" " ;;
      [[:print:]]) FILTER+="$key" ;;
    esac
  done
}

main "$@"
