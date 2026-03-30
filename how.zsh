# how - a command-line assistant for zsh
# Source this file from your .zshrc:
#   source /path/to/how.zsh

HOW_DIR="${0:a:h}"

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
    print -rz -- "$result"
  fi
}

_how_last_history_cmd() {
  local cmd
  cmd=$(fc -ln -1 2>/dev/null)
  cmd="${cmd#"${cmd%%[![:space:]]*}"}"
  cmd="${cmd%"${cmd##*[![:space:]]}"}"
  [[ -n "$cmd" ]] || return 1
  print -r -- "$cmd"
}

how() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: how <what you want to do>" >&2
    return 1
  fi

  _how_run how "$PWD" "$@"
}

fix() {
  local last_cmd
  if ! last_cmd=$(_how_last_history_cmd); then
    echo "fix: no previous command to fix" >&2
    return 1
  fi

  _how_run fixit "$PWD" "$last_cmd" -- "$@"
}
