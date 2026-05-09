defmodule CodePuppyControl.Tool.Runner do
  @moduledoc """
  Dispatches tool invocations with permission checks, schema validation,
  telemetry, timeout handling, and callback integration.

  The runner is the single entry point for executing tools from the agent
  loop. It handles the full lifecycle:

  1. Resolve the tool module (registry → legacy fallback)
  2. Trigger `:pre_tool_call` callbacks (fail-closed — can block execution)
  3. Check permissions
  4. Validate arguments against the tool's schema
  5. Invoke the tool with timeout protection
  6. Trigger `:post_tool_call` callbacks with result and duration
  7. Emit telemetry events

  ## Callback Integration

  The runner integrates with the `CodePuppyControl.Callbacks` system:

  - **`:pre_tool_call`** — Triggered before execution. Uses `trigger_raw/2`
    (fail-closed) so any callback returning `%{blocked: true}` or crashing
    prevents the tool from executing. This is the path through which
    `HookEngine` PreToolUse hooks actually block tools.

  - **`:post_tool_call`** — Triggered after execution. Receives
    `tool_name`, `args`, `result`, `duration_ms`, and `context`. Observer-only
    — cannot block. Enables HookEngine PostToolUse hooks, tracing, and
    cost estimation to receive execution context.

  ## Usage

      # From the agent loop:
      result = Runner.invoke(:command_runner, %{"command" => "ls"}, %{run_id: "run-1"})

      # Returns:
      {:ok, %{success: true, stdout: "...", ...}}
      # or
      {:error, "permission denied: ..."}
      # or
      {:error, "blocked by pre_tool_call hook: ..."}
      # or
      {:error, "validation failed: ..."}

  ## Telemetry

  Emits the following events:

  - `[:tool, :invoke, :start]` — before invocation, with `%{tool_name, args}`
  - `[:tool, :invoke, :stop]` — after invocation, with `%{tool_name, result, duration_ms}`

  ## Timeout

  Default timeout is 60 seconds. Override per-invocation via context `:timeout` key.
  """

  require Logger

  alias CodePuppyControl.Callbacks
  alias CodePuppyControl.Callbacks.FilePermission
  alias CodePuppyControl.Tool.Registry
  alias CodePuppyControl.Tool.Schema
  alias CodePuppyControl.Approvals
  alias CodePuppyControl.PolicyEngine.PolicyRule.{Allow, Deny, AskUser}

  @default_timeout_ms 60_000

  # ── Public API ───────────────────────────────────────────────────────────

  @doc """
  Invokes a tool by name with the given arguments and context.

  ## Arguments

  - `tool_name` — Atom name of the tool (e.g., `:command_runner`)
  - `args` — Map of arguments (already decoded from JSON string) or raw
    JSON string to decode
  - `context` — Map with runtime metadata. Supported keys:
    - `:run_id` — Agent run identifier (for telemetry/logging)
    - `:agent_module` — The agent module requesting the tool
    - `:timeout` — Override timeout in milliseconds

  ## Returns

  - `{:ok, result}` — Tool executed successfully
  - `{:error, reason}` — Tool failed (permission denied, validation error,
    timeout, or tool error)

  ## Examples

      iex> Runner.invoke(:command_runner, %{"command" => "echo hello"}, %{run_id: "run-1"})
      {:ok, %{success: true, stdout: "hello\\n", ...}}

      iex> Runner.invoke(:nonexistent_tool, %{}, %{})
      {:error, "Tool not found: nonexistent_tool"}
  """
  @spec invoke(atom() | String.t(), map() | String.t(), map()) :: {:ok, term()} | {:error, term()}
  def invoke(tool_name, args, context \\ %{})

  def invoke(tool_name, args, context) when is_atom(tool_name) do
    args = decode_args(args)

    with {:ok, module} <- resolve_tool(tool_name) do
      do_invoke(module, tool_name, args, context)
    end
  end

  def invoke(tool_name, args, context) when is_binary(tool_name) do
    # Provider may emit tool names as strings. Safely resolve to an existing
    # atom only — String.to_existing_atom/1 fails if the atom was never created,
    # preventing unbounded atom creation from untrusted input.
    case safe_atomize_name(tool_name) do
      {:ok, atom_name} -> invoke(atom_name, args, context)
      :error -> {:error, "Tool not found: #{tool_name}"}
    end
  end

  def invoke(tool_name, _args, _context) do
    {:error, "Invalid tool name: #{inspect(tool_name)}"}
  end

  # Safely convert a string to an existing atom. Returns :error if the atom
  # doesn't exist, avoiding unbounded atom creation from provider strings.
  defp safe_atomize_name(name) when is_binary(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> :error
  end

  # ── Resolution ───────────────────────────────────────────────────────────

  @doc """
  Resolves a tool name to its implementing module.

  Checks the registry first, then falls back to legacy module resolution
  (converting atom name like `:echo_tool` to module `Tool.EchoTool`).
  """
  @spec resolve_tool(atom()) :: {:ok, module()} | {:error, String.t()}
  def resolve_tool(tool_name) when is_atom(tool_name) do
    case Registry.lookup(tool_name) do
      {:ok, module} ->
        {:ok, module}

      :error ->
        # Legacy fallback: resolve from atom name to module
        case legacy_resolve(tool_name) do
          {:ok, module} -> {:ok, module}
          :error -> {:error, "Tool not found: #{tool_name}"}
        end
    end
  end

  defp legacy_resolve(tool_name) when is_atom(tool_name) do
    module_name =
      tool_name
      |> Atom.to_string()
      |> String.split("_")
      |> Enum.map(&String.capitalize/1)
      |> Enum.join()

    # Try Tool.* namespace first (matches existing convention)
    module = Module.concat([Tool, module_name])

    if Code.ensure_loaded?(module) and function_exported?(module, :execute, 1) do
      {:ok, module}
    else
      :error
    end
  end

  # ── Dispatch ─────────────────────────────────────────────────────────────

  defp do_invoke(module, tool_name, args, context) do
    timeout =
      Map.get(context, :timeout) ||
        module_default_timeout(module) ||
        @default_timeout_ms

    tool_name_str = Atom.to_string(tool_name)

    # ── Pre-tool-call callback trigger (fail-closed) ──────────────
    # If any :pre_tool_call callback returns %{blocked: true} or
    # crashes (:callback_failed), execution is prevented.
    # This integrates HookEngine PreToolUse hooks so they can
    # actually block tools through the Runner path.
    case pre_tool_check(tool_name_str, args, context) do
      :ok ->
        # Emit start telemetry
        start_time = System.monotonic_time(:millisecond)

        :telemetry.execute(
          [:tool, :invoke, :start],
          %{system_time: System.system_time()},
          %{tool_name: tool_name, args: args}
        )

        # Run the tool with timeout protection
        result = run_with_timeout(module, tool_name, args, context, timeout)

        # Emit stop telemetry
        duration_ms = System.monotonic_time(:millisecond) - start_time

        :telemetry.execute(
          [:tool, :invoke, :stop],
          %{duration: duration_ms},
          %{tool_name: tool_name, result: result}
        )

        # ── Post-tool-call callback trigger (observer) ──────────
        # Post hooks are observers — they cannot block. They receive
        # result and duration_ms so hook scripts can access tool
        # results and timing via the callback chain.
        post_tool_notify(tool_name_str, args, result, duration_ms, context)

        result

      {:blocked, reason} ->
        {:error, "blocked by pre_tool_call hook: #{reason}"}
    end
  end

  # ── Callback Integration ────────────────────────────────────────────────

  # Pre-tool-call: fail-closed security check.
  # Uses trigger_raw to get individual results (not merged), matching
  # the RunShellCommand fail-closed pattern.
  # Any callback returning %{blocked: true} or :callback_failed prevents
  # execution — we cannot determine the callback's intent on crash,
  # so we deny to be safe.
  @spec pre_tool_check(String.t(), map(), map()) :: :ok | {:blocked, String.t()}
  defp pre_tool_check(tool_name, args, context) do
    try do
      results = Callbacks.trigger_raw(:pre_tool_call, [tool_name, args, context])

      blocked? =
        Enum.any?(results, fn
          %{blocked: true} -> true
          :callback_failed -> true
          {:callback_failed, _} -> true
          _ -> false
        end)

      if blocked? do
        reason =
          Enum.find_value(results, fn
            %{blocked: true, reason: r} -> r
            %{blocked: true} -> "no reason provided"
            :callback_failed -> "callback crashed (fail-closed)"
            {:callback_failed, _} -> "callback crashed (fail-closed)"
            _ -> nil
          end)

        {:blocked, reason || "blocked by security plugin"}
      else
        :ok
      end
    rescue
      e ->
        Logger.warning("pre_tool_call callback check raised: #{Exception.message(e)}")
        # Fail-closed: callback errors block execution
        {:blocked, "Security callback failed (fail-closed)"}
    catch
      :exit, reason ->
        Logger.warning("pre_tool_call callback check crashed: #{inspect(reason)}")
        {:blocked, "Security callback crashed (fail-closed)"}
    end
  end

  # Post-tool-call: observer-only notification.
  # Cannot block. Fires after tool execution completes with the
  # full result and duration so that hook scripts and observers
  # (e.g. HookEngine PostToolUse, tracing, cost estimation) receive
  # the execution context they expect.
  @spec post_tool_notify(String.t(), map(), term(), integer(), map()) :: :ok
  defp post_tool_notify(tool_name, args, result, duration_ms, context) do
    try do
      Callbacks.trigger(:post_tool_call, [tool_name, args, result, duration_ms, context])
    rescue
      e ->
        Logger.warning("post_tool_call callback raised: #{Exception.message(e)}")
    catch
      :exit, reason ->
        Logger.warning("post_tool_call callback crashed: #{inspect(reason)}")
    end

    :ok
  end

  defp run_with_timeout(module, tool_name, args, context, timeout) do
    # Permission check runs in the calling process (agent loop / REPL)
    # so that interactive prompts (IO.gets) work correctly via the
    # standard group leader chain.
    case check_permission(module, args, context) do
      :ok ->
        # Tool execution with timeout protection
        task =
          Task.async(fn ->
            with :ok <- validate_args(module, args) do
              invoke_tool(module, tool_name, args, context)
            end
          end)

        case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} ->
            result

          nil ->
            Logger.warning("Tool #{tool_name} timed out after #{timeout}ms")
            {:error, "Tool #{tool_name} timed out after #{timeout}ms"}

          {:exit, reason} ->
            Logger.warning("Tool #{tool_name} crashed: #{inspect(reason)}")
            {:error, "Tool #{tool_name} crashed: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Permission Check ─────────────────────────────────────────────────────

  # Tool names that involve file operations and should go through
  # the FilePermission callback chain in addition to the tool's own
  # permission_check/2.
  @file_tools [
    :create_file,
    :replace_in_file,
    :edit_file,
    :delete_file,
    :delete_snippet,
    :cp_create_file,
    :cp_replace_in_file,
    :cp_edit_file,
    :cp_delete_file,
    :cp_delete_snippet,
    :cp_read_file,
    :cp_list_files,
    :cp_grep,
    # Staged tools — defense-in-depth (slash-only, but if somehow invoked
    # through Runner they still need file-permission checks)
    :stage_create,
    :stage_replace,
    :stage_delete_snippet,
    :stage_delete_file,
    :apply_staged_changes
  ]

  defp check_permission(module, args, context) do
    # Step 1: Tool's own permission_check (path validation, etc.)
    with :ok <- tool_permission_check(module, args, context) do
      # Step 2: FilePermission callback chain for file-related tools
      tool_name = tool_name_from_module(module)

      if tool_name in @file_tools do
        file_permission_check(tool_name, args, context)
      else
        :ok
      end
    end
  end

  defp tool_permission_check(module, args, context) do
    if function_exported?(module, :permission_check, 2) do
      try do
        case module.permission_check(args, context) do
          :ok -> :ok
          {:deny, reason} -> {:error, "permission denied: #{reason}"}
        end
      rescue
        e -> {:error, "permission check failed: #{Exception.message(e)}"}
      end
    else
      # No permission_check defined — allow by default
      :ok
    end
  end

  defp file_permission_check(tool_name, args, context) do
    file_path = file_target_from_args(tool_name, args)
    operation = file_operation_from_tool(tool_name)

    if file_path == "" do
      # No target path in args — skip file permission check.
      # Directory-oriented tools (cp_list_files, cp_grep) return "." when
      # the directory arg is absent, so they always go through the check.
      # Refs: code_puppy-mmk.3
      :ok
    else
      case FilePermission.check(context, file_path, operation, nil, nil, nil,
             tool_name: Atom.to_string(tool_name)
           ) do
        %Allow{} ->
          :ok

        %Deny{reason: reason} ->
          {:error, "permission denied: #{reason}"}

        %AskUser{prompt: prompt} ->
          handle_ask_user(tool_name, file_path, operation, prompt, args, context)
      end
    end
  end

  # Handles the AskUser decision from PolicyEngine by checking for
  # one-shot approvals, optionally prompting the user in interactive CLI
  # contexts, and recording the request as pending for later `/approve`
  # resolution.
  #
  # Resolution order:
  #   1. Consume a matching one-shot approval from the Approvals store → :ok
  #   2. Record pending (so `/approve last` works even if the interactive
  #      prompt times out or the process is killed)
  #   3. Interactive CLI prompt (when `interactive_approval?` is true):
  #        - approved → remove the pending entry, return :ok
  #        - declined / EOF → leave pending, return error with guidance
  #   4. Non-interactive → leave pending, return error with guidance
  @spec handle_ask_user(atom(), String.t(), String.t(), String.t() | nil, map(), map()) ::
          :ok | {:error, String.t()}
  defp handle_ask_user(tool_name, file_path, operation, prompt, args, context) do
    request =
      Approvals.Request.new(
        operation: operation,
        file_path: file_path,
        tool_name: Atom.to_string(tool_name),
        prompt: prompt,
        session_id: Map.get(context, :session_id),
        run_id: Map.get(context, :run_id),
        args: args
      )

    # Step 1: Check for a pre-existing one-shot approval
    case Approvals.consume_approval(request) do
      :allowed ->
        :ok

      :no_match ->
        # Step 2: Always record pending BEFORE attempting interactive
        # prompt, so `/approve last` can resolve the request even if the
        # interactive prompt times out, is killed, or receives EOF.
        :ok = Approvals.record_pending(request)

        # Step 3: Interactive CLI prompt (only when explicitly enabled)
        if interactive_approval?(context) do
          interactive_prompt_and_approve(request, prompt, context)
        else
          # Non-interactive → leave pending, return error with guidance
          {:error, format_approval_required_msg(request, prompt, context)}
        end
    end
  end

  # Returns true when the tool invocation context indicates an interactive
  # REPL session that supports terminal prompts. Guarded by an explicit
  # context flag to prevent blocking non-interactive contexts (e.g. TUI,
  # HTTP API, subagent runs).
  @spec interactive_approval?(map()) :: boolean()
  defp interactive_approval?(context) do
    Map.get(context, :interactive_approval?, false) or
      Map.get(context, :approval_mode) == :cli
  end

  # Prompts the user in the terminal for approval of a file operation.
  # Returns :ok if the user types "y" or "yes"; returns an error otherwise.
  # On EOF (piped input), fails closed.
  #
  # The pending request has **already** been recorded by `handle_ask_user/6`
  # before this function is called, so `/approve last` works even if the
  # interactive prompt is interrupted.  When the user approves inline, we
  # remove the pending entry so it does not remain as a stale pending.
  #
  # The actual IO reader is injectable via `context[:approval_reader]`
  # so that tests can simulate yes/no/eof without relying on IO.gets
  # inside Task.async.  The default reader is `&IO.gets/1`.
  @spec interactive_prompt_and_approve(Approvals.Request.t(), String.t() | nil, map()) ::
          :ok | {:error, String.t()}
  defp interactive_prompt_and_approve(request, prompt, context) do
    reader = Map.get(context, :approval_reader, &IO.gets/1)
    prompt_text = prompt || "Confirm file operation"
    label = "#{request.operation} #{request.file_path} (#{request.tool_name})"
    IO.puts("")
    IO.puts(IO.ANSI.yellow() <> "    ⚠ #{prompt_text}: #{label}" <> IO.ANSI.reset())
    IO.write(IO.ANSI.yellow() <> "    Approve? [y/N] " <> IO.ANSI.reset())

    # The reader function returns the line string (including newline)
    # or :eof when no more input is available.
    case reader.("") do
      :eof ->
        # Non-interactive (piped input) — leave pending, fail closed
        {:error, format_approval_required_msg(request, prompt, context)}

      line when is_binary(line) ->
        trimmed = String.trim(line)

        if trimmed in ["y", "Y", "yes", "YES", "Yes"] do
          IO.puts(IO.ANSI.green() <> "    ✓ Approved" <> IO.ANSI.reset())
          # Approved inline — remove the pending entry so it does not
          # remain as a stale pending request.
          :ok = Approvals.remove_pending(request.id)
          :ok
        else
          # Declined — leave pending for later `/approve last`
          {:error, format_approval_required_msg(request, prompt, context)}
        end
    end
  end

  # Formats the error message when a file operation requires user approval.
  # Guidance is context-aware:
  #   - In interactive CLI contexts, mention both `/approve last` and the
  #     inline y/N prompt.
  #   - In non-interactive / declined contexts, prefer `/approve last`
  #     (typing y at the normal REPL prompt will not help).
  @spec format_approval_required_msg(Approvals.Request.t(), String.t() | nil, map()) ::
          String.t()
  defp format_approval_required_msg(_request, prompt, context) do
    base = "File operation requires user approval"
    detail = if prompt && prompt != "", do: ": #{prompt}", else: ""

    guidance =
      if interactive_approval?(context) do
        ". Use /approve last to approve and retry"
      else
        ". Use /approve last to approve and retry"
      end

    base <> detail <> guidance
  end

  defp tool_name_from_module(module) when is_atom(module) do
    if function_exported?(module, :name, 0) do
      module.name()
    else
      module
    end
  end

  # Map tool atoms to file operation verbs for the callback chain.
  # cp_* variants are the agent-facing mutation wrappers (see CpFileMods)
  # and map to the same operations as their unprefixed counterparts.
  defp file_operation_from_tool(:create_file), do: "create"
  defp file_operation_from_tool(:replace_in_file), do: "write"
  defp file_operation_from_tool(:edit_file), do: "edit"
  defp file_operation_from_tool(:delete_file), do: "delete"
  defp file_operation_from_tool(:delete_snippet), do: "delete"
  defp file_operation_from_tool(:cp_create_file), do: "create"
  defp file_operation_from_tool(:cp_replace_in_file), do: "write"
  defp file_operation_from_tool(:cp_edit_file), do: "edit"
  defp file_operation_from_tool(:cp_delete_file), do: "delete"
  defp file_operation_from_tool(:cp_delete_snippet), do: "delete"
  defp file_operation_from_tool(:cp_read_file), do: "read"
  defp file_operation_from_tool(:cp_list_files), do: "list"
  defp file_operation_from_tool(:cp_grep), do: "search"
  defp file_operation_from_tool(:stage_create), do: "create"
  defp file_operation_from_tool(:stage_replace), do: "write"
  defp file_operation_from_tool(:stage_delete_snippet), do: "delete"
  defp file_operation_from_tool(:stage_delete_file), do: "delete"
  defp file_operation_from_tool(:apply_staged_changes), do: "write"
  defp file_operation_from_tool(_), do: "access"

  # ── Target Path Extraction ───────────────────────────────────────────────

  @doc """
  Extracts the target file or directory path from tool arguments.

  Different tool types use different argument names for their target path:

  - Directory-oriented tools (`cp_list_files`, `cp_grep`) use `"directory"`
    with a default of `"."` when absent (matching the tools' actual default cwd)
  - File-oriented tools use `"file_path"` with `"path"` as fallback
  - If no recognized key is found for file tools, returns an empty string

  This helper ensures `FilePermission.check` always receives the actual
  target path regardless of the tool's argument naming convention.

  Refs: code_puppy-mmk.3 (Shepherd blocker — directory tools must not
  bypass FilePermission when the directory arg is omitted)

  ## Examples

      iex> Runner.file_target_from_args(:cp_create_file, %{"file_path" => "lib/foo.ex"})
      "lib/foo.ex"

      iex> Runner.file_target_from_args(:cp_list_files, %{"directory" => "lib/"})
      "lib/"

      iex> Runner.file_target_from_args(:cp_list_files, %{})
      "."

      iex> Runner.file_target_from_args(:cp_grep, %{"directory" => "src/", "search_string" => "TODO"})
      "src/"

      iex> Runner.file_target_from_args(:cp_grep, %{"search_string" => "TODO"})
      "."
  """
  @spec file_target_from_args(atom(), map()) :: String.t()
  def file_target_from_args(tool_name, args) when is_atom(tool_name) and is_map(args) do
    directory_tools = [:cp_list_files, :cp_grep, :list_files, :grep]

    if tool_name in directory_tools do
      Map.get(args, "directory", ".")
    else
      Map.get(args, "file_path", Map.get(args, "path", ""))
    end
  end

  # ── Argument Validation ──────────────────────────────────────────────────

  defp validate_args(module, args) do
    if function_exported?(module, :parameters, 0) do
      schema = module.parameters()

      case Schema.validate(schema, args) do
        {:ok, _validated} -> :ok
        {:error, violations} -> {:error, "validation failed: #{Enum.join(violations, "; ")}"}
      end
    else
      # No schema defined — skip validation
      :ok
    end
  end

  # ── Tool Invocation ──────────────────────────────────────────────────────

  defp invoke_tool(module, tool_name, args, context) do
    try do
      if function_exported?(module, :invoke, 2) do
        module.invoke(args, context)
      else
        # Legacy fallback: call execute/1
        module.execute(args)
      end
    rescue
      e ->
        Logger.warning("Tool #{tool_name} raised: #{Exception.message(e)}")
        {:error, "Tool #{tool_name} error: #{Exception.message(e)}"}
    catch
      kind, reason ->
        Logger.warning("Tool #{tool_name} threw #{kind}: #{inspect(reason)}")
        {:error, "Tool #{tool_name} #{kind}: #{inspect(reason)}"}
    end
  end

  # ── Module Timeout ────────────────────────────────────────────────────────

  # Tools that need a different default timeout (e.g. interactive tools
  # that wait for user input) can export `tool_timeout/0` returning a
  # positive integer in milliseconds. When absent, returns nil and the
  # runner falls back to @default_timeout_ms (60 s).
  @spec module_default_timeout(module()) :: pos_integer() | nil
  defp module_default_timeout(module) when is_atom(module) do
    if function_exported?(module, :tool_timeout, 0) do
      module.tool_timeout()
    else
      nil
    end
  end

  # ── Argument Decoding ────────────────────────────────────────────────────

  @doc """
  Decodes tool arguments from the format the LLM provides.

  LLM providers typically send tool arguments as a JSON string. This
  function handles both string and map inputs gracefully.
  """
  @spec decode_args(String.t() | map() | nil) :: map()
  def decode_args(args)

  def decode_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, map} when is_map(map) -> map
      {:ok, other} -> %{"_raw" => other}
      {:error, _} -> %{"_raw" => args}
    end
  end

  def decode_args(args) when is_map(args), do: args
  def decode_args(nil), do: %{}
  def decode_args(_other), do: %{}

  # ── Context Builder ──────────────────────────────────────────────────────

  @doc """
  Builds a standard tool invocation context map.

  Useful for constructing context from agent loop state.

  ## Examples

      iex> Runner.build_context(run_id: "run-1", agent_module: MyApp.Agents.ElixirDev)
      %{run_id: "run-1", agent_module: MyApp.Agents.ElixirDev}
  """
  @spec build_context(keyword()) :: map()
  def build_context(opts \\ []) do
    opts
    |> Enum.into(%{})
    |> Map.put_new(:timestamp, System.system_time(:millisecond))
  end
end
