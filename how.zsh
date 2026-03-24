# how - a command-line assistant for zsh
# Source this file from your .zshrc:
#   source /path/to/how.zsh

HOW_DIR="${0:a:h}"

how() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: how <what you want to do>" >&2
    return 1
  fi

  local result
  result=$("$HOW_DIR/how-backend.rb" "$PWD" "$@")

  if [[ $? -ne 0 ]]; then
    return 1
  fi

  # Backend outputs explanation lines to stderr directly.
  # stdout contains just the command to execute.
  if [[ -n "$result" ]]; then
    print -z "$result"
  fi
}
