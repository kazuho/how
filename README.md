# how

A command-line assistant for zsh. Describe what you want to do in plain English, and `how` generates the shell command for you — ready to execute or edit.

## Setup

Add the following to your `.zshrc`:

```zsh
source /path/to/how.zsh
```

### Requirements

- zsh
- Ruby
- [Codex CLI](https://github.com/openai/codex) (`codex` command)

## Usage

```
how <what you want to do>
```

The generated command appears at your prompt. Press Enter to run it, or edit it first.

### Examples

```
how do I find all TODO comments in this project
how do I list files sorted by size
how do I compress this directory into a tar.gz
```
