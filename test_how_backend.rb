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

class TestBuildHowPrompt < Minitest::Test
  def test_includes_cwd
    prompt = How.build_how_prompt(cwd: "/home/user", prompt: "list files")
    assert_includes prompt, "/home/user"
  end

  def test_includes_user_request
    prompt = How.build_how_prompt(cwd: "/tmp", prompt: "find large files")
    assert_includes prompt, "find large files"
  end
end

class TestBuildFixPrompt < Minitest::Test
  def test_includes_failed_command
    prompt = How.build_fix_prompt(cwd: "/tmp", failed_cmd: "gti status")
    assert_includes prompt, "gti status"
  end

  def test_includes_user_hint
    prompt = How.build_fix_prompt(cwd: "/tmp", failed_cmd: "ls", user_hint: "sort by size")
    assert_includes prompt, "sort by size"
  end

  def test_no_user_hint
    prompt = How.build_fix_prompt(cwd: "/tmp", failed_cmd: "ls")
    refute_includes prompt, "User instructions:"
  end

  def test_includes_terminal_output
    prompt = How.build_fix_prompt(
      cwd: "/tmp", failed_cmd: "gcc foo.c",
      terminal_output: "foo.c:3: error: expected ';'"
    )
    assert_includes prompt, "foo.c:3: error: expected ';'"
    assert_includes prompt, "Recent terminal output:"
  end

  def test_no_terminal_output
    prompt = How.build_fix_prompt(cwd: "/tmp", failed_cmd: "ls")
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

  def test_normalize_terminal_output_scrubs_invalid_bytes
    output = How.normalize_terminal_output("ok\xFFng".b)
    assert_equal "ok\ufffdng", output
  end
end

class TestTerminalOutputRequiredForFix < Minitest::Test
  def test_exits_when_no_tmux_or_screen
    original_tmux = ENV.delete("TMUX")
    original_sty = ENV.delete("STY")

    err = assert_raises(SystemExit) { How.terminal_output_required_for_fix }
    assert_equal 1, err.status
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

  def test_prompt_includes_privilege_info
    prompt = How.build_how_prompt(cwd: "/tmp", prompt: "list files")
    assert_includes prompt, "Running as"
  end

  def test_fix_prompt_includes_privilege_info
    prompt = How.build_fix_prompt(cwd: "/tmp", failed_cmd: "ls")
    assert_includes prompt, "Running as"
  end
end

class TestModel < Minitest::Test
  def test_default_model
    ENV.delete("HOW_MODEL")
    assert_equal "5.3-codex-spark", How.model
  end

  def test_custom_model
    ENV["HOW_MODEL"] = "gpt-4o"
    assert_equal "gpt-4o", How.model
  ensure
    ENV.delete("HOW_MODEL")
  end
end

class TestCallCodex < Minitest::Test
  def test_scrubs_invalid_bytes_in_output_file
    fake_status = Object.new
    def fake_status.success? = true

    tmpfile = Tempfile.new("how-test")
    File.binwrite(tmpfile.path, "COMMAND: echo ok\xFF".b)

    open3_singleton = class << Open3; self; end
    tempfile_singleton = class << Tempfile; self; end

    open3_singleton.alias_method :__orig_capture3_for_test, :capture3
    tempfile_singleton.alias_method :__orig_new_for_test, :new

    open3_singleton.define_method(:capture3) { |*| ["", "", fake_status] }
    tempfile_singleton.define_method(:new) { |*| tmpfile }

    result = How.call_codex("ignored")
    assert_equal "COMMAND: echo ok\ufffd", result
  ensure
    if open3_singleton&.method_defined?(:__orig_capture3_for_test)
      open3_singleton.alias_method :capture3, :__orig_capture3_for_test
      open3_singleton.remove_method :__orig_capture3_for_test
    end

    if tempfile_singleton&.method_defined?(:__orig_new_for_test)
      tempfile_singleton.alias_method :new, :__orig_new_for_test
      tempfile_singleton.remove_method :__orig_new_for_test
    end

    tmpfile.close!
  end
end
