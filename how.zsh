# how - a command-line assistant for zsh
# Source this file from your .zshrc:
#   source /path/to/how.zsh

HOW_DIR="${0:a:h}"

# Hooks to track the last command and its exit status.
# Skip our own commands so fixit sees the actual failed command.
_how_preexec() {
  case "$1" in
    how\ *|fix|fix\ *) ;;
    *) _HOW_LAST_CMD="$1" ;;
  esac
}
_how_precmd() {
  local e=$?
  # Only update if preexec recorded a command (i.e., it wasn't skipped)
  [[ -n "$_HOW_PENDING" ]] && _HOW_LAST_EXIT=$e
  _HOW_PENDING=
}
_how_preexec_mark() {
  case "$1" in
    how\ *|fix|fix\ *) _HOW_PENDING= ;;
    *) _HOW_PENDING=1 ;;
  esac
}
autoload -Uz add-zsh-hook
add-zsh-hook preexec _how_preexec
add-zsh-hook preexec _how_preexec_mark
add-zsh-hook precmd _how_precmd

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
    print -z "$result"
  fi
}

fix() {
  if [[ -z "$_HOW_LAST_CMD" ]]; then
    echo "fix: no previous command to fix" >&2
    return 1
  fi

  local result
  result=$("$HOW_DIR/how-backend.rb" fixit "$PWD" "$_HOW_LAST_EXIT" "$_HOW_LAST_CMD")

  if [[ $? -ne 0 ]]; then
    return 1
  fi

  if [[ -n "$result" ]]; then
    print -z "$result"
  fi
}
