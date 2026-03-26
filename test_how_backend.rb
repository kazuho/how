#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "how-backend"

class TestParseResponse < Minitest::Test
  def test_simple_command
    response = "COMMAND: ls -lS"
    cmd, explanation = How.parse_response(response)
    assert_equal "ls -lS", cmd
    assert_equal "", explanation
  end

  def test_command_with_explanation
    response = "Lists files sorted by size.\n\nCOMMAND: ls -lS"
    cmd, explanation = How.parse_response(response)
    assert_equal "ls -lS", cmd
    assert_equal "Lists files sorted by size.", explanation
  end

  def test_command_with_backticks
    response = "COMMAND: `ls -lS`"
    cmd, explanation = How.parse_response(response)
    assert_equal "ls -lS", cmd
  end

  def test_command_with_triple_backticks
    response = "COMMAND: ```ls -lS```"
    cmd, explanation = How.parse_response(response)
    assert_equal "ls -lS", cmd
  end

  def test_no_command_returns_nil
    response = "I don't know how to do that."
    cmd, explanation = How.parse_response(response)
    assert_nil cmd
  end

  def test_multiline_explanation
    response = "This finds all Ruby files.\nIt searches recursively.\n\nCOMMAND: find . -name '*.rb'"
    cmd, explanation = How.parse_response(response)
    assert_equal "find . -name '*.rb'", cmd
    assert_equal "This finds all Ruby files.\nIt searches recursively.", explanation
  end

  def test_multiple_command_lines_takes_first
    response = "COMMAND: ls -l\nCOMMAND: ls -la"
    cmd, _explanation = How.parse_response(response)
    assert_equal "ls -l", cmd
  end

end

class TestSystemPrompts < Minitest::Test
  def test_how_prompt_includes_cwd
    prompt = How.system_prompt_how(cwd: "/home/user", prompt: "list files")
    assert_includes prompt, "/home/user"
  end

  def test_how_prompt_includes_privilege_info
    prompt = How.system_prompt_how(cwd: "/tmp", prompt: "list files")
    assert_includes prompt, "Running as"
  end

  def test_fix_prompt_includes_privilege_info
    prompt = How.system_prompt_fix(cwd: "/tmp")
    assert_includes prompt, "Running as"
  end
end

class TestBuildPrompts < Minitest::Test
  def test_how_prompt_includes_request
    prompt = How.build_how_prompt(cwd: "/tmp", prompt: "find large files")
    assert_includes prompt, "find large files"
  end

  def test_fix_prompt_includes_failed_command
    prompt = How.build_fix_prompt(cwd: "/tmp", failed_cmd: "gti status", exit_code: "127")
    assert_includes prompt, "gti status"
    assert_includes prompt, "127"
  end

  def test_fix_prompt_includes_user_hint
    prompt = How.build_fix_prompt(cwd: "/tmp", failed_cmd: "ls", exit_code: "0", user_hint: "sort by size")
    assert_includes prompt, "sort by size"
  end

  def test_fix_prompt_no_user_hint
    prompt = How.build_fix_prompt(cwd: "/tmp", failed_cmd: "ls", exit_code: "0")
    refute_includes prompt, "User instructions:"
  end

  def test_fix_prompt_includes_terminal_output
    prompt = How.build_fix_prompt(
      cwd: "/tmp", failed_cmd: "gcc foo.c", exit_code: "1",
      terminal_output: "foo.c:3: error: expected ';'"
    )
    assert_includes prompt, "foo.c:3: error: expected ';'"
    assert_includes prompt, "Recent terminal output:"
  end

  def test_fix_prompt_no_terminal_output
    prompt = How.build_fix_prompt(cwd: "/tmp", failed_cmd: "ls", exit_code: "0")
    refute_includes prompt, "Recent terminal output:"
  end
end

class TestCaptureTerminalOutput < Minitest::Test
  def test_no_tmux_no_screen
    original_tmux = ENV.delete("TMUX")
    original_sty = ENV.delete("STY")
    assert_nil How.capture_terminal_output
  ensure
    ENV["TMUX"] = original_tmux if original_tmux
    ENV["STY"] = original_sty if original_sty
  end
end

class TestPrivilegeContext < Minitest::Test
  def test_returns_string
    ctx = How.privilege_context
    assert_kind_of String, ctx
    refute_empty ctx
  end

  def test_mentions_running_as
    ctx = How.privilege_context
    assert_includes ctx, "Running as"
  end
end

class TestModelConfig < Minitest::Test
  def setup
    @orig_uri = ENV.delete("HOW_URI")
    @orig_model = ENV.delete("HOW_MODEL")
  end

  def teardown
    ENV["HOW_URI"] = @orig_uri if @orig_uri
    ENV["HOW_MODEL"] = @orig_model if @orig_model
  end

  def test_default_uses_codex
    config = How.model_config
    assert_equal :codex, config[:type]
    assert_nil config[:model]
  end

  def test_model_name_uses_codex
    ENV["HOW_MODEL"] = "gpt-4o"
    config = How.model_config
    assert_equal :codex, config[:type]
    assert_equal "gpt-4o", config[:model]
  end

  def test_uri_uses_api
    ENV["HOW_URI"] = "http://localhost:11434"
    ENV["HOW_MODEL"] = "some-model"
    config = How.model_config
    assert_equal :api, config[:type]
    assert_equal "http://localhost:11434", config[:base_url]
    assert_equal "some-model", config[:model]
  end

  def test_uri_without_model_auto_detects
    ENV["HOW_URI"] = "http://localhost:11434"
    config = How.model_config
    assert_equal :api, config[:type]
    assert_equal "http://localhost:11434", config[:base_url]
    # model will be auto-detected (or "default" on failure)
    assert_kind_of String, config[:model]
  end
end

class TestExecuteTool < Minitest::Test
  def test_allowed_command
    result = How.execute_tool("run_command", { "command" => "which ls" })
    refute_includes result, "rejected"
  end

  def test_blocked_command
    result = How.execute_tool("run_command", { "command" => "brew install foo" })
    assert_includes result, "rejected"
  end

  def test_ls_allowed
    result = How.execute_tool("run_command", { "command" => "ls /tmp" })
    refute_includes result, "rejected"
  end

  def test_grep_allowed
    result = How.execute_tool("run_command", { "command" => "grep -r foo /dev/null" })
    refute_includes result, "rejected"
  end

  def test_unknown_tool
    result = How.execute_tool("unknown", {})
    assert_includes result, "Unknown tool"
  end
end

class TestCommandAllowed < Minitest::Test
  def test_which
    assert How.command_allowed?("which sudo")
  end

  def test_ls
    assert How.command_allowed?("ls -la /tmp")
  end

  def test_brew_list_allowed
    assert How.command_allowed?("brew list")
  end

  def test_brew_info_allowed
    assert How.command_allowed?("brew info clang-format")
  end

  def test_brew_install_blocked
    refute How.command_allowed?("brew install foo")
  end

  def test_brew_upgrade_blocked
    refute How.command_allowed?("brew upgrade foo")
  end

  def test_rm_blocked
    refute How.command_allowed?("rm -rf /")
  end

  def test_curl_blocked
    refute How.command_allowed?("curl http://example.com")
  end

  def test_apt_allowed
    assert How.command_allowed?("apt list --installed")
  end
end
