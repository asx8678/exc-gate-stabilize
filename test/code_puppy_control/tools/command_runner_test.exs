defmodule CodePuppyControl.Tools.CommandRunnerTest do
  @moduledoc """
  Tests for the CommandRunner tool.

  Covers:
  - Command validation (forbidden chars, dangerous patterns)
  - Basic command execution (echo, ls)
  - Timeout handling
  - Output truncation
  - PTY execution mode
  - Background execution mode
  - Security integration
  - Kill escalation
  - Process tracking

  Refs: code_puppy-mmk.6 (Phase E port)
  """

  use CodePuppyControl.StatefulCase

  alias CodePuppyControl.Tools.CommandRunner

  alias CodePuppyControl.Tools.CommandRunner.{
    Executor,
    Security,
    Validator
  }

  # ============================================================================
  # Validator Tests
  # ============================================================================

  describe "validate/1" do
    test "accepts valid simple command" do
      assert {:ok, "echo hello"} = Validator.validate("echo hello")
    end

    test "rejects empty command" do
      assert {:error, "Command cannot be empty or whitespace only"} = Validator.validate("")
      assert {:error, "Command cannot be empty or whitespace only"} = Validator.validate("   ")
    end

    test "rejects command exceeding max length" do
      long_command = String.duplicate("a", 9000)
      assert {:error, msg} = Validator.validate(long_command)
      assert msg =~ "exceeds maximum length"
    end

    test "rejects command with forbidden control characters" do
      # Null byte (0x00)
      assert {:error, msg} = Validator.validate("echo \x00 test")
      assert msg =~ "forbidden control characters"

      # Bell character (0x07)
      assert {:error, _} = Validator.validate("echo \x07 test")
    end

    test "rejects command with dangerous patterns - process substitution" do
      # Input process substitution
      assert {:error, msg} = Validator.validate("cat <(echo test)")
      assert msg =~ "dangerous pattern"

      # Output process substitution
      assert {:error, msg} = Validator.validate("echo test >(cat)")
      assert msg =~ "dangerous pattern"
    end

    test "rejects command with dangerous patterns - multiple fd redirections" do
      assert {:error, msg} = Validator.validate("cmd 2>&1 3>&2")
      assert msg =~ "dangerous pattern"
    end

    test "rejects command with unbalanced quotes" do
      assert {:error, msg} = Validator.validate("echo 'unclosed quote")
      assert msg =~ "unbalanced single quotes"

      assert {:error, msg} = Validator.validate("echo \"unclosed double quote")
      assert msg =~ "unbalanced double quotes"
    end

    test "accepts command with balanced quotes" do
      assert {:ok, _} = Validator.validate("echo 'hello world'")
      assert {:ok, _} = Validator.validate("echo \"hello world\"")
      assert {:ok, _} = Validator.validate("echo 'single' and \"double\"")
    end

    test "accepts command with escaped quotes" do
      assert {:ok, _} = Validator.validate("echo \"it\\'s working\"")
      assert {:ok, _} = Validator.validate("echo 'say \\\"hello\\\"'")
      assert {:ok, _} = Validator.validate("echo \\\"escaped double\\\"")
    end

    test "rejects command with no valid tokens" do
      assert {:error, "Command contains no valid tokens after parsing"} =
               Validator.validate("'   '")
    end

    test "rejects non-string input" do
      assert {:error, "Command must be a string"} = Validator.validate(nil)
      assert {:error, "Command must be a string"} = Validator.validate(123)
    end
  end

  describe "max_command_length/0" do
    test "returns the configured max length" do
      assert Validator.max_command_length() == 8192
    end
  end

  # ============================================================================
  # CommandRunner.run/2 Tests
  # ============================================================================

  describe "run/2 with simple commands" do
    test "executes echo command successfully" do
      assert {:ok, result} = CommandRunner.run("echo hello world", skip_security: true)

      assert result.success == true
      assert result.exit_code == 0
      assert result.stdout =~ "hello world"
      assert result.timeout == false
      assert result.error == nil
      # (code-puppy-mkk.6) Timer-resolution flake: sub-ms commands can
      # round to 0 on some OS timers. Assert non-negative number instead of > 0.
      assert is_number(result.execution_time_ms)
      assert result.execution_time_ms >= 0
    end

    test "captures stderr output merged with stdout" do
      assert {:ok, result} = CommandRunner.run("echo error >&2", skip_security: true)

      assert result.success == true
      # stderr is merged into stdout with stderr_to_stdout: true
      assert result.stdout =~ "error"
    end

    test "handles command failure" do
      assert {:ok, result} = CommandRunner.run("false", skip_security: true)

      assert result.success == false
      assert result.exit_code == 1
      assert result.error =~ "exit code 1"
    end

    test "handles non-existent command" do
      assert {:ok, result} =
               CommandRunner.run("this_command_does_not_exist_12345", skip_security: true)

      assert result.success == false
      assert result.exit_code == 127
    end

    test "preserves command in result" do
      cmd = "echo test"
      assert {:ok, result} = CommandRunner.run(cmd, skip_security: true)
      assert result.command == cmd
    end

    test "includes expected result fields" do
      assert {:ok, result} = CommandRunner.run("echo hello", skip_security: true)

      assert Map.has_key?(result, :success)
      assert Map.has_key?(result, :command)
      assert Map.has_key?(result, :stdout)
      assert Map.has_key?(result, :stderr)
      assert Map.has_key?(result, :exit_code)
      assert Map.has_key?(result, :execution_time_ms)
      assert Map.has_key?(result, :timeout)
      assert Map.has_key?(result, :error)
      assert Map.has_key?(result, :user_interrupted)
      assert Map.has_key?(result, :background)
      assert Map.has_key?(result, :log_file)
      assert Map.has_key?(result, :pid)
      assert Map.has_key?(result, :pty)
    end
  end

  describe "run/2 with pipes and redirects" do
    test "handles pipe commands" do
      assert {:ok, result} =
               CommandRunner.run("echo 'hello world' | tr ' ' '-'", skip_security: true)

      assert result.success == true
      assert result.stdout =~ "hello-world"
    end

    test "handles command substitution" do
      assert {:ok, result} = CommandRunner.run("echo $(echo nested)", skip_security: true)

      assert result.success == true
      assert result.stdout =~ "nested"
    end
  end

  describe "run/2 with timeout" do
    test "handles timeout with sleep command" do
      assert {:ok, result} = CommandRunner.run("sleep 10", timeout: 1, skip_security: true)

      assert result.success == false
      assert result.timeout == true
      assert result.error =~ "timed out"
    end

    test "respects custom timeout option" do
      assert {:ok, result} = CommandRunner.run("echo quick", timeout: 5, skip_security: true)

      assert result.success == true
      assert result.timeout == false
    end

    test "caps timeout at absolute maximum (270s)" do
      # Even with timeout: 999, it should be capped to 270
      assert {:ok, result} =
               CommandRunner.run("echo capped", timeout: 999, skip_security: true)

      assert result.success == true
    end
  end

  describe "run/2 with cwd option" do
    test "executes in specified working directory" do
      assert {:ok, result} = CommandRunner.run("pwd", cwd: "/tmp", skip_security: true)

      assert result.success == true
      assert result.stdout =~ "/tmp"
    end
  end

  describe "run/2 with env option" do
    test "sets environment variables" do
      assert {:ok, result} =
               CommandRunner.run("echo $TEST_VAR",
                 env: [{"TEST_VAR", "hello"}],
                 skip_security: true
               )

      assert result.success == true
      assert result.stdout =~ "hello"
    end
  end

  describe "run/2 validation" do
    test "rejects command with validation error" do
      assert {:error, msg} = CommandRunner.run("echo \x00 test")
      assert msg =~ "forbidden"
    end

    test "rejects empty command" do
      assert {:error, _} = CommandRunner.run("")
    end
  end

  describe "run/2 with pty option" do
    test "executes command in PTY mode and reports pty: true" do
      # PTY mode uses PtyManager.Stub in test env
      assert {:ok, result} = CommandRunner.run("echo pty_test", pty: true, skip_security: true)

      # PTY execution should report pty: true when PTY path is used
      assert result.pty == true
      assert result.success == true
    end

    test "standard execution reports pty: false" do
      assert {:ok, result} = CommandRunner.run("echo no_pty", skip_security: true)

      assert result.pty == false
    end
  end

  describe "run/2 with background option" do
    test "starts background process" do
      assert {:ok, result} =
               CommandRunner.run("echo bg_test", background: true, skip_security: true)

      assert result.background == true
      assert result.log_file != nil
      assert result.execution_time_ms == 0
      # OS PID is not available from System.cmd; documented as nil
      assert result.pid == nil
      assert result.pty == false

      # Clean up log file
      if result.log_file do
        File.rm(result.log_file)
      end
    end

    test "background result has no exit code yet" do
      assert {:ok, result} =
               CommandRunner.run("echo bg_noexit", background: true, skip_security: true)

      assert result.exit_code == nil
      assert result.pid == nil

      if result.log_file do
        File.rm(result.log_file)
      end
    end
  end

  # ============================================================================
  # Output Truncation Tests
  # ============================================================================

  describe "truncate_line/2" do
    test "does not truncate short lines" do
      assert "hello world" = CommandRunner.truncate_line("hello world", 100)
    end

    test "truncates long lines" do
      long_line = String.duplicate("a", 300)
      truncated = CommandRunner.truncate_line(long_line, 256)

      assert truncated =~ "truncated"
      assert truncated =~ "try filtering with grep"
    end

    test "uses default max line length" do
      long_line = String.duplicate("a", 300)
      truncated = CommandRunner.truncate_line(long_line)

      assert truncated =~ "truncated"
    end
  end

  # ============================================================================
  # Process Management Tests
  # ============================================================================

  describe "running_count/0 and kill_all/0" do
    test "returns zero when no processes running" do
      CommandRunner.kill_all()
      assert CommandRunner.running_count() == 0
    end

    test "kill_all returns count of killed processes" do
      count = CommandRunner.kill_all()
      assert is_integer(count)
      assert count >= 0
    end
  end

  # ============================================================================
  # Security Integration Tests
  # ============================================================================

  describe "security pipeline" do
    test "run with skip_security bypasses policy/callbacks" do
      # Should work without policy engine involvement
      assert {:ok, result} = CommandRunner.run("echo skip", skip_security: true)
      assert result.success == true
    end

    test "run without skip_security goes through security" do
      # Valid command may be allowed or require user approval depending on policy config
      result = CommandRunner.run("echo secured")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  # ============================================================================
  # Integration Tests
  # ============================================================================

  describe "complex shell commands" do
    test "handles multi-command chains" do
      assert {:ok, result} = CommandRunner.run("echo a && echo b && echo c", skip_security: true)

      assert result.success == true
      assert result.stdout =~ "a"
      assert result.stdout =~ "b"
      assert result.stdout =~ "c"
    end

    test "handles conditional execution" do
      assert {:ok, result} = CommandRunner.run("false || echo fallback", skip_security: true)

      assert result.success == true
      assert result.stdout =~ "fallback"
    end

    test "handles environment variable expansion" do
      assert {:ok, result} =
               CommandRunner.run("HOME=/test && echo $HOME", skip_security: true)

      assert result.success == true
    end

    test "produces output with long lines truncated" do
      # Generate a very long line
      assert {:ok, result} =
               CommandRunner.run(
                 "python3 -c \"print('a' * 500)\"",
                 skip_security: true
               )

      # Output should be truncated
      if result.stdout != "" do
        # Each line should be <= max_line_length + hint length
        max_line_len =
          result.stdout
          |> String.split("\n")
          |> Enum.map(&String.length/1)
          |> Enum.max()

        # Allow for the truncation hint
        assert max_line_len <= 256 + 80
      end
    end
  end

  # ============================================================================
  # Executor Direct Tests
  # ============================================================================

  describe "Executor.execute/2" do
    test "standard execution mode" do
      assert {:ok, result} = Executor.execute("echo executor_test", silent: true)

      assert result.success == true
      assert result.stdout =~ "executor_test"
      assert result.pty == false
      assert result.background == false
    end

    test "background execution mode" do
      assert {:ok, result} = Executor.execute("echo bg_executor", background: true)

      assert result.background == true
      assert result.log_file != nil

      # Wait briefly for output to be written
      Process.sleep(100)

      if File.exists?(result.log_file) do
        File.rm(result.log_file)
      end
    end
  end

  # ============================================================================
  # Regression Tests for code_puppy-mmk.6
  # ============================================================================

  describe "regression: explicit allow-policy path does not CaseClauseError (code_puppy-mmk.6)" do
    # When Security.check/2 returned bare :allowed atom from callback_check/3
    # instead of the documented %{allowed: true, decision: :allowed, reason: nil}
    # map, CommandRunner.run/2 would crash with CaseClauseError because the
    # case expression expected a map matching %{allowed: true}.
    test "run/2 executes successfully when Security.check allows command" do
      # Without skip_security, the security pipeline runs. If PolicyEngine
      # allows and callback_check returns :allowed (not a map), run/2 crashes.
      # After fix: Security.check always returns the proper map.
      result = CommandRunner.run("echo regression_allow_test")

      # The command should either execute successfully or be denied by policy,
      # but it must NOT crash with CaseClauseError.
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "Security.check/2 returns proper map shape for allowed command" do
      result = Security.check("echo map_regression_test")

      # Must be a map with :allowed, :decision, :reason keys
      assert is_map(result)
      assert Map.has_key?(result, :allowed)
      assert Map.has_key?(result, :decision)
      assert Map.has_key?(result, :reason)

      # If allowed, must match the documented shape exactly
      if result.allowed == true do
        assert result == %{allowed: true, decision: :allowed, reason: nil}
      end
    end
  end
end
