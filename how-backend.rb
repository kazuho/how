#!/usr/bin/env ruby
# frozen_string_literal: true

# how-backend.rb - Backend for the `how` and `fix` zsh commands
# Calls an LLM to generate shell commands from natural language.
#
# Usage:
#   how-backend.rb how <cwd> <prompt...>
#   how-backend.rb fixit <cwd> <exit_code> <failed_command> [-- <user instructions>]
#
# Environment variables:
#   HOW_URI   - OpenAI-compatible API base URL (e.g., "http://host:11434").
#               If set, uses the API directly instead of codex CLI.
#   HOW_MODEL - model name. If HOW_URI is set and HOW_MODEL is not, auto-detects
#               from the endpoint. If HOW_URI is not set, passed to codex CLI.
#
# - Outputs the generated command to stdout
# - Outputs explanation to stderr

require "open3"
require "tempfile"
require "net/http"
require "json"
require "uri"

module How
  MAX_TOOL_ROUNDS = 5

  module_function

  def debug?
    ENV["HOW_DEBUG"] == "1"
  end

  def debug_log(label, obj)
    return unless debug?
    if obj.is_a?(String)
      $stderr.puts "[how-debug] #{label}: #{obj}"
    else
      $stderr.puts "[how-debug] #{label}: #{JSON.pretty_generate(obj)}"
    end
  end

  def model_config
    base_url = ENV["HOW_URI"]
    model_name = ENV["HOW_MODEL"]
    if base_url
      model_name = detect_model(base_url) if model_name.nil? || model_name.empty?
      { type: :api, base_url: base_url, model: model_name }
    else
      { type: :codex, model: model_name }
    end
  end

  def detect_model(base_url)
    uri = URI("#{base_url}/v1/models")
    response = Net::HTTP.get_response(uri)
    data = JSON.parse(response.body)
    data["data"]&.first&.dig("id") || "default"
  rescue
    "default"
  end

  def shell_env
    shell = File.basename(ENV["SHELL"] || "sh")
    os = `uname -sr 2>/dev/null`.strip
    "#{shell} on #{os}"
  end

  def privilege_context
    uid = `id -u 2>/dev/null`.strip
    if uid == "0"
      "Running as root."
    else
      user = ENV["USER"] || `whoami 2>/dev/null`.strip
      privesc = %w[sudo doas].find { |c| system("which #{c} >/dev/null 2>&1") }
      if privesc
        "Running as #{user}. Use `#{privesc}` for commands that require root."
      else
        "Running as #{user}. Use `su -c '...'` for commands that require root."
      end
    end
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

  def investigate_instruction
    if model_config[:type] == :api
      "Use the run_command tool to investigate the system. To call a tool, respond with a JSON tool_call object, not with XML tags or text."
    else
      "You may run read-only commands to investigate the system (e.g., which, man, ls, grep, dpkg, brew, pkg-config, apt list, rpm)."
    end
  end

  def system_prompt_how(cwd:, prompt:)
    <<~PROMPT
      You are a shell command generator. The user describes what they want to do, and you suggest the command for them to run.
      Do NOT execute the user's request yourself. Only suggest the command.

      Respond with:
      1. A brief explanation of what the command does (1-2 lines, optional if obvious).
      2. A line that starts with exactly `COMMAND: ` followed by the shell command.

      Environment: #{shell_env}
      Current directory: #{cwd}
      #{privilege_context}

      Before answering:
      - #{investigate_instruction}
      - Check that commands you plan to suggest are actually available.
      - Prefer concise commands tailored to the current environment over generic ones.

      Always respond with exactly one COMMAND: line. If the task requires multiple commands, chain them with && or ; or pipes as appropriate.
      Do not wrap the command in backticks or code blocks.
    PROMPT
  end

  def system_prompt_fix(cwd:)
    <<~PROMPT
      You are a shell command fixer. The user ran a command and wants to fix or modify it.
      If the command failed (non-zero exit code), diagnose and correct the error.
      If the user provides additional instructions, modify the command accordingly.

      Respond with:
      1. A brief explanation of what you changed (1-2 lines).
      2. A line that starts with exactly `COMMAND: ` followed by the corrected shell command.

      Environment: #{shell_env}
      Current directory: #{cwd}
      #{privilege_context}

      Before answering:
      - #{investigate_instruction}
      - Check that commands you plan to suggest are actually available.
      - Prefer concise commands tailored to the current environment over generic ones.

      Always respond with exactly one COMMAND: line.
      Do not wrap the command in backticks or code blocks.
    PROMPT
  end

  # For codex: build a single flat prompt (codex handles tools internally)
  def build_how_prompt(cwd:, prompt:)
    "#{system_prompt_how(cwd: cwd, prompt: prompt)}\nUser request: #{prompt}"
  end

  def build_fix_prompt(cwd:, failed_cmd:, exit_code:, user_hint: "", terminal_output: nil)
    sys = system_prompt_fix(cwd: cwd)
    request = "Previous command: #{failed_cmd}\nExit code: #{exit_code}"
    request += "\nUser instructions: #{user_hint}" unless user_hint.empty?
    request += "\n\nRecent terminal output:\n#{terminal_output}" if terminal_output
    "#{sys}\n#{request}"
  end

  TOOL_DEFINITION = {
    type: "function",
    function: {
      name: "run_command",
      description: "Run a read-only shell command to investigate the system (e.g., which, ls, man, grep, dpkg, apt list, brew, pkg-config, rpm). Do not use this to run commands that modify the system.",
      parameters: {
        type: "object",
        properties: {
          command: { type: "string", description: "The shell command to run" }
        },
        required: ["command"]
      }
    }
  }.freeze

  SANDBOX_PROFILE_MACOS = "(version 1)(allow default)(deny network*)(deny file-write*)(allow file-write* (literal \"/dev/null\"))"

  def sandbox_command(cmd)
    if RUBY_PLATFORM =~ /darwin/
      ["sandbox-exec", "-p", SANDBOX_PROFILE_MACOS, "sh", "-c", cmd]
    elsif system("which bwrap >/dev/null 2>&1")
      ["bwrap", "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp", "--unshare-net", "sh", "-c", cmd]
    else
      nil
    end
  end

  def execute_tool(name, arguments)
    case name
    when "run_command"
      cmd = arguments["command"]
      sandboxed = sandbox_command(cmd)
      if sandboxed
        output, _status = Open3.capture2e(*sandboxed)
      else
        return "Error: no sandbox available (install bubblewrap for sandboxed command execution)"
      end
      output.strip
    else
      "Unknown tool: #{name}"
    end
  end

  def call_api(config, system:, user_message:)
    uri = URI("#{config[:base_url]}/v1/chat/completions")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 10
    http.read_timeout = 60

    messages = [
      { role: "system", content: system },
      { role: "user", content: user_message }
    ]
    debug_log "request", messages

    MAX_TOOL_ROUNDS.times do |round|
      body = {
        model: config[:model],
        messages: messages,
        tools: [TOOL_DEFINITION]
      }

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(body)

      response = http.request(request)
      unless response.is_a?(Net::HTTPSuccess)
        $stderr.puts "how: API error #{response.code}: #{response.body}"
        return nil
      end

      data = JSON.parse(response.body)
      choice = data.dig("choices", 0, "message")
      debug_log "response[#{round}]", choice

      # Some models (e.g., Qwen) put chain-of-thought in a separate field
      # and leave content null until thinking is done
      reasoning = choice["reasoning_content"] || choice["thinking"]
      text_content = choice["content"]

      tool_calls = choice["tool_calls"]
      if tool_calls && !tool_calls.empty?
        messages << choice

        tool_calls.each do |tc|
          args = JSON.parse(tc.dig("function", "arguments"))
          result = execute_tool(tc.dig("function", "name"), args)
          debug_log "tool[#{tc.dig("function", "name")}]", result
          messages << {
            role: "tool",
            tool_call_id: tc["id"],
            content: result
          }
        end
      else
        text = text_content&.strip
        text = reasoning&.strip if text.nil? || text.empty?
        if text.nil? || text.empty?
          $stderr.puts "how: model returned empty content"
          return nil
        end
        # Strip <think>...</think> tags if present
        text = text.gsub(%r{<think>.*?</think>}m, "").strip

        cmd, _ = parse_response(text)
        return text if cmd

        # Missing COMMAND: line — ask the model to correct
        messages << { role: "assistant", content: text }
        messages << { role: "user", content: "Your response must include a line starting with `COMMAND: ` followed by the shell command. Please try again." }
      end
    end

    $stderr.puts "how: too many rounds"
    nil
  rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Net::OpenTimeout, Net::ReadTimeout => e
    $stderr.puts "how: API connection error: #{e.message}"
    nil
  end

  def call_codex(prompt)
    config = model_config
    tmpfile = Tempfile.new("how")
    begin
      cmd = ["codex", "exec",
        "--skip-git-repo-check",
        "-C", ENV["HOME"],
        "-s", "read-only"]
      cmd += ["-m", config[:model]] if config[:model]
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

  def call_llm(system:, user_message:)
    config = model_config
    if config[:type] == :api
      call_api(config, system: system, user_message: user_message)
    else
      # Codex path: flatten into a single prompt
      call_codex("#{system}\n#{user_message}")
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

  def generate(system:, user_message:)
    response = call_llm(system: system, user_message: user_message)
    if response.nil?
      $stderr.puts "how: no response from LLM"
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

    generate(
      system: system_prompt_how(cwd: cwd, prompt: prompt),
      user_message: "User request: #{prompt}"
    )
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

    request = "Previous command: #{failed_cmd}\nExit code: #{exit_code}"
    request += "\nUser instructions: #{user_hint}" unless user_hint.empty?
    request += "\n\nRecent terminal output:\n#{terminal_output}" if terminal_output

    generate(
      system: system_prompt_fix(cwd: cwd),
      user_message: request
    )
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
