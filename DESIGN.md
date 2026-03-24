# The `how` zsh extension

`how` is a command-line assistant for zsh. It implements the `how` command:

* The command interprets the entire argument and generates a command line that does that.
* But instead of executing it, it sets up the next command line of the shell as such, so that the user can execute it just by hitting return, or edit the command line as necessary.
* Before setting up the command line, how command may emit explanations, clarifying its understanding of the user's intent and how the generated command line is organized.

The command should use the codex command (or possibly its MCP server) as the backend for interpreting the user input and generating the command line. As it is normal to traverse between various directories when using shell, the workspace directory of the backend should be set to `$HOME` or `/`, and the backend should be given minimal privileges (e.g., read directories and files, run select commands (man, ls, cat, which, ...) that do not modify files or touch the network).

After implementing an MVP of `how`, we should consider implementing `fix it`, that fixes the last command being executed and provides it in the prompt.
