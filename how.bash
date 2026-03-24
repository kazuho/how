# how - a command-line assistant for bash
# Source this file from your .bashrc:
#   source /path/to/how.bash

HOW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Hooks to track the last command and its exit status.
# Uses DEBUG trap as a preexec equivalent, PROMPT_COMMAND as precmd.
_how_debug_trap() {
  local cmd="$BASH_COMMAND"
  case "$cmd" in
    how\ *|fix|fix\ *|_how_*) ;;
    *) _HOW_LAST_CMD="$cmd"; _HOW_PENDING=1 ;;
  esac
}
_how_prompt_cmd() {
  local e=$?
  if [[ -n "$_HOW_PENDING" ]]; then
    _HOW_LAST_EXIT=$e
    _HOW_PENDING=
  fi
}
trap '_how_debug_trap' DEBUG
PROMPT_COMMAND="_how_prompt_cmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"

# Present a command for the user to edit and run.
# bash has no print -z; use read -e -i to pre-fill readline (requires bash 4+).
_how_present() {
  local cmd="$1"
  local edited
  read -e -i "$cmd" -p "$ " edited
  if [[ -n "$edited" ]]; then
    history -s "$edited"
    eval "$edited"
  fi
}

how() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: how <what you want to do>" >&2
    return 1
  fi

  local result
  result=$("$HOW_DIR/how-backend.rb" how "$PWD" "$@")

  if [[ $? -ne 0 ]]; then
    return 1
  fi

  if [[ -n "$result" ]]; then
    _how_present "$result"
  fi
}

fix() {
  if [[ -z "$_HOW_LAST_CMD" ]]; then
    echo "fix: no previous command to fix" >&2
    return 1
  fi

  local result
  result=$("$HOW_DIR/how-backend.rb" fixit "$PWD" "$_HOW_LAST_EXIT" "$_HOW_LAST_CMD" -- "$@")

  if [[ $? -ne 0 ]]; then
    return 1
  fi

  if [[ -n "$result" ]]; then
    _how_present "$result"
  fi
}
