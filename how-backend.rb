#!/usr/bin/env ruby
# frozen_string_literal: true

# how-backend.rb - Backend for the `how` and `fix` zsh commands
# Calls codex to generate shell commands from natural language.
#
# Usage:
#   how-backend.rb how <cwd> <prompt...>
#   how-backend.rb fixit <cwd> <exit_code> <failed_command> [-- <user instructions>]
#
# Environment variables:
#   HOW_MODEL - model to use (default: o4-mini)
#
# - Outputs the generated command to stdout
# - Outputs explanation to stderr

require "open3"
require "tempfile"

module How
  DEFAULT_MODEL = "5.3-codex-spark"

  module_function

  def model
    ENV["HOW_MODEL"] || DEFAULT_MODEL
  end

  def shell_env
    shell = File.basename(ENV["SHELL"] || "sh")
    uname = `uname -a 2>/dev/null`.strip
    "#{shell} on #{uname}"
  end

  # Capture recent terminal output from tmux or screen, if available.
  def capture_terminal_output(lines: 50)
    if ENV["TMUX"]
      output = `tmux capture-pane -p -S -#{lines} 2>/dev/null`.strip
      return output unless output.empty?
    elsif ENV["STY"]
      tmpfile = "/tmp/how_screen_hardcopy.#{$$}"
      system("screen", "-X", "hardcopy", tmpfile)
      if File.exist?(tmpfile)
        output = File.read(tmpfile).strip
        File.delete(tmpfile)
        return output unless output.empty?
      end
    end
    nil
  end

  def build_how_prompt(cwd:, prompt:)
    <<~PROMPT
      You are a shell command generator. The user describes what they want to do, and you respond with:
      1. A brief explanation of what the command does (1-2 lines, optional if obvious).
      2. A line that starts with exactly `COMMAND: ` followed by the shell command.

      The user's current shell is #{shell_env}. Current directory: #{cwd}

      You may run read-only commands to investigate the system before answering (e.g., which, man, ls, grep, dpkg, brew, pkg-config, apt list, rpm).

      Always respond with exactly one COMMAND: line. If the task requires multiple commands, chain them with && or ; or pipes as appropriate.
      Do not wrap the command in backticks or code blocks.

      User request: #{prompt}
    PROMPT
  end

  def build_fix_prompt(cwd:, failed_cmd:, exit_code:, user_hint: "", terminal_output: nil)
    system_prompt = <<~PROMPT
      You are a shell command fixer. The user ran a command and wants to fix or modify it.
      If the command failed (non-zero exit code), diagnose and correct the error.
      If the user provides additional instructions, modify the command accordingly.

      Respond with:
      1. A brief explanation of what you changed (1-2 lines).
      2. A line that starts with exactly `COMMAND: ` followed by the corrected shell command.

      The user's current shell is #{shell_env}. Current directory: #{cwd}

      You may run read-only commands to investigate the system before answering (e.g., which, man, ls, grep, dpkg, brew, pkg-config, apt list, rpm).

      Always respond with exactly one COMMAND: line.
      Do not wrap the command in backticks or code blocks.
    PROMPT

    request = "Previous command: #{failed_cmd}\nExit code: #{exit_code}"
    request += "\nUser instructions: #{user_hint}" unless user_hint.empty?
    if terminal_output
      request += "\n\nRecent terminal output:\n#{terminal_output}"
    end

    "#{system_prompt}\n#{request}"
  end

  def call_codex(prompt)
    tmpfile = Tempfile.new("how")
    begin
      cmd = ["codex", "exec",
        "--skip-git-repo-check",
        "-C", ENV["HOME"],
        "-s", "read-only"]
      cmd += ["-m", model] if ENV["HOW_MODEL"]
      cmd += ["-o", tmpfile.path, prompt]

      _stdout, _stderr, status = Open3.capture3(*cmd)

      return nil unless status.success?

      result = File.read(tmpfile.path).strip
      result.empty? ? nil : result
    ensure
      tmpfile.close
      tmpfile.unlink
    end
  end

  def parse_response(response)
    lines = response.lines.map(&:chomp)

    cmd_line = lines.find { |l| l.start_with?("COMMAND: ") }
    return [nil, ""] if cmd_line.nil?

    cmd = cmd_line.sub(/^COMMAND: /, "").strip
    # Strip backticks if the model wrapped the command
    cmd = cmd.gsub(/^`+|`+$/, "")

    explanation = lines.reject { |l| l.start_with?("COMMAND: ") }.join("\n").strip
    [cmd, explanation]
  end

  def generate(full_prompt)
    response = call_codex(full_prompt)
    if response.nil?
      $stderr.puts "how: no response from codex"
      exit 1
    end

    cmd, explanation = parse_response(response)

    if cmd.nil?
      $stderr.puts response
      $stderr.puts "how: could not extract a command from the response"
      exit 1
    end

    $stderr.puts explanation unless explanation.empty?
    puts cmd
  end

  def run_how(args)
    if args.length < 2
      $stderr.puts "Usage: how-backend.rb how <cwd> <prompt...>"
      exit 1
    end

    cwd = args[0]
    prompt = args[1..].join(" ")

    generate(build_how_prompt(cwd: cwd, prompt: prompt))
  end

  def run_fixit(args)
    if args.length < 3
      $stderr.puts "Usage: how-backend.rb fixit <cwd> <exit_code> <failed_command>"
      exit 1
    end

    cwd = args[0]
    exit_code = args[1]

    # Split on "--" separator: args before are <failed_command>, after are <user instructions>
    sep = args[2..].index("--")
    if sep
      failed_cmd = args[2, sep].join(" ")
      user_hint = args[(2 + sep + 1)..].join(" ")
    else
      failed_cmd = args[2..].join(" ")
      user_hint = ""
    end

    terminal_output = capture_terminal_output

    generate(build_fix_prompt(
      cwd: cwd,
      failed_cmd: failed_cmd,
      exit_code: exit_code,
      user_hint: user_hint,
      terminal_output: terminal_output
    ))
  end
end

if __FILE__ == $0
  mode = ARGV.shift

  case mode
  when "how"
    How.run_how(ARGV)
  when "fixit"
    How.run_fixit(ARGV)
  else
    $stderr.puts "Usage: how-backend.rb {how|fixit} ..."
    exit 1
  end
end
