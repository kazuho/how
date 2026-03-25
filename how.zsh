# how - a command-line assistant for zsh
# Source this file from your .zshrc:
#   source /path/to/how.zsh

HOW_DIR="${0:a:h}"

# Hooks to track the last command and its exit status.
# Skip our own commands so fix sees the actual failed command.
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

# Run a backend command with a spinner, capturing stdout.
# Explanation (stderr) passes through to the terminal.
# Spinner runs in background; backend runs in foreground.
_how_run() {
  local tmpfile=$(mktemp)
  local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

  # Suppress job control notifications for the spinner
  setopt local_options no_monitor no_notify

  # Start spinner in background
  (
    local i=0
    while true; do
      printf "\r%s " "${spin:$i:1}" >&2
      (( i = (i + 1) % ${#spin} ))
      sleep 0.1
    done
  ) &
  local spinner_pid=$!

  # Ensure spinner is cleaned up on interrupt
  trap "kill $spinner_pid 2>/dev/null; wait $spinner_pid 2>/dev/null; printf '\r  \r' >&2; rm -f '$tmpfile'; return 130" INT TERM

  # Run backend in foreground, capture stdout
  "$HOW_DIR/how-backend.rb" "$@" > "$tmpfile"
  local exit_code=$?

  # Stop spinner and clear
  kill $spinner_pid 2>/dev/null
  wait $spinner_pid 2>/dev/null
  printf "\r  \r" >&2

  trap - INT TERM

  local result=$(<"$tmpfile")
  rm -f "$tmpfile"

  if [[ $exit_code -ne 0 ]]; then
    return 1
  fi

  if [[ -n "$result" ]]; then
    print -z "$result"
  fi
}

how() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: how <what you want to do>" >&2
    return 1
  fi

  _how_run how "$PWD" "$@"
}

fix() {
  if [[ -z "$_HOW_LAST_CMD" ]]; then
    echo "fix: no previous command to fix" >&2
    return 1
  fi

  _how_run fixit "$PWD" "$_HOW_LAST_EXIT" "$_HOW_LAST_CMD" -- "$@"
}
