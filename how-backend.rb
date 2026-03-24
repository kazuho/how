#!/usr/bin/env ruby
# frozen_string_literal: true

# how-backend.rb - Backend for the `how` zsh command
# Calls codex to generate shell commands from natural language.
#
# Usage: how-backend.rb <cwd> <prompt...>
# - Outputs the generated command to stdout
# - Outputs explanation to stderr

require "open3"
require "json"
require "tempfile"

def main
  if ARGV.length < 2
    $stderr.puts "Usage: how-backend.rb <cwd> <prompt...>"
    exit 1
  end

  cwd = ARGV[0]
  prompt = ARGV[1..].join(" ")

  system_prompt = <<~PROMPT
    You are a shell command generator. The user describes what they want to do, and you respond with:
    1. A brief explanation of what the command does (1-2 lines, optional if obvious).
    2. A line that starts with exactly `COMMAND: ` followed by the shell command.

    The user's current shell is zsh on macOS. Current directory: #{cwd}

    Always respond with exactly one COMMAND: line. If the task requires multiple commands, chain them with && or ; or pipes as appropriate.
    Do not wrap the command in backticks or code blocks.
  PROMPT

  full_prompt = "#{system_prompt}\nUser request: #{prompt}"

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

def call_codex(prompt)
  tmpfile = Tempfile.new("how")
  begin
    _stdout, _stderr, status = Open3.capture3(
      "codex", "exec",
      "--skip-git-repo-check",
      "-C", ENV["HOME"],
      "-s", "read-only",
      "-o", tmpfile.path,
      prompt
    )

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

main
