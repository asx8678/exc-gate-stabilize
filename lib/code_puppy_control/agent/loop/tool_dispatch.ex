defmodule CodePuppyControl.Agent.Loop.ToolDispatch do
  @moduledoc """
  Tool dispatch logic for Agent.Loop.

  Handles resolving tool names (safely converting provider-returned
  strings to atoms), dispatching tool calls via `Tool.Runner`, and
  formatting tool results for the conversation history.

  Extracted from `Agent.Loop` to keep it under the 600-line hard cap.
  """

  require Logger

  alias CodePuppyControl.Agent.Events
  alias CodePuppyControl.Tool.Runner

  @doc """
  Dispatch all pending tool calls from a turn, appending result messages.

  Resolves string tool names against the allowed set, invokes each tool,
  and appends tool-result messages to the conversation. Disallowed tools
  receive an error result message instead.
  """
  @spec dispatch_tool_calls(map(), map(), [map()]) :: [map()]
  def dispatch_tool_calls(state, turn, messages) do
    allowed = MapSet.new(state.agent_module.allowed_tools())

    Enum.reduce(turn.pending_tool_calls, messages, fn tool_call, acc ->
      # Provider-emitted tool call names may arrive as strings, but
      # allowed_tools uses atoms. Resolve string names against the known
      # allowed set — never call String.to_atom/1 on untrusted input.
      resolved_name = resolve_tool_name(tool_call.name, allowed)
      tool_call = %{tool_call | name: resolved_name}

      # (code_puppy-be7.3) Sanitize tool_call.id before using it in
      # result messages and events. A custom llm_module that bypasses
      # LLMAdapter may produce empty/invalid IDs.
      safe_id = sanitize_tool_call_id(tool_call.id)
      tool_call = %{tool_call | id: safe_id}

      if MapSet.member?(allowed, resolved_name) do
        execute_tool_call(state, tool_call, acc)
      else
        Logger.warning(
          "Agent.Loop: tool #{inspect(resolved_name)} not in allowed_tools for #{inspect(state.agent_module)}"
        )

        # Emit balanced start/end lifecycle events so TUI spinners
        # (and any other subscribers) see a proper pair.
        Events.publish(
          Events.tool_call_start(
            state.run_id,
            state.session_id,
            resolved_name,
            tool_call.arguments,
            safe_id
          )
        )

        result_msg = %{
          role: "tool",
          tool_call_id: safe_id,
          content: "Error: tool #{inspect(resolved_name)} is not available"
        }

        Events.publish(
          Events.tool_call_end(
            state.run_id,
            state.session_id,
            resolved_name,
            {:error, :tool_not_allowed},
            safe_id
          )
        )

        acc ++ [result_msg]
      end
    end)
  end

  @doc """
  Resolve a tool name (possibly a string from the provider) to an atom
  by matching against the known allowed set.

  Returns the atom if found, or the original name (string or atom) if
  no match — caller treats unresolved strings as not-allowed.
  """
  @spec resolve_tool_name(atom() | String.t() | term(), MapSet.t(atom())) ::
          atom() | String.t() | term()
  def resolve_tool_name(name, _allowed) when is_atom(name), do: name

  def resolve_tool_name(name, allowed) when is_binary(name) do
    case Enum.find(allowed, &(Atom.to_string(&1) == name)) do
      nil -> name
      atom -> atom
    end
  end

  def resolve_tool_name(name, _allowed), do: name

  @doc """
  Execute a single tool call, publish events, and append the result message.
  """
  @spec execute_tool_call(map(), map(), [map()]) :: [map()]
  def execute_tool_call(state, tool_call, messages) do
    # (code_puppy-be7.3) Sanitize tool_call.id before emitting events
    # and storing in message history. Defense-in-depth: IDs should already
    # be sanitized by sanitize_tool_call_ids/1 in finalize_turn/3, but
    # we guard here too in case dispatch_tool_calls is called directly.
    safe_id = sanitize_tool_call_id(tool_call.id)

    Events.publish(
      Events.tool_call_start(
        state.run_id,
        state.session_id,
        tool_call.name,
        tool_call.arguments,
        safe_id
      )
    )

    # Dispatch via Tool.Runner (registry + permission check + validation + timeout)
    context =
      Runner.build_context(
        run_id: state.run_id,
        session_id: state.session_id
      )

    result = Runner.invoke(tool_call.name, tool_call.arguments, context)

    Events.publish(
      Events.tool_call_end(state.run_id, state.session_id, tool_call.name, result, safe_id)
    )

    # Check if agent wants to halt
    case state.agent_module.on_tool_result(tool_call.name, result, state.agent_state) do
      {:cont, _new_agent_state} ->
        result_msg = %{
          role: "tool",
          tool_call_id: safe_id,
          content: format_tool_result(result)
        }

        messages ++ [result_msg]

      {:halt, reason} ->
        Logger.info("Agent.Loop: agent halted after tool #{tool_call.name}: #{inspect(reason)}")

        messages
    end
  end

  defp generate_safe_dispatch_id do
    "call_dispatch_#{System.unique_integer([:positive])}"
  end

  @doc """
  Sanitize a single tool_call ID.

  Ensures the ID is a non-empty string containing only `[A-Za-z0-9_-]+`.
  Invalid, empty, or nil IDs are replaced with a generated safe ID.

  This is the single source of truth for tool-call ID sanitization
  across `Agent.Loop` and `ToolDispatch`.
  """
  @spec sanitize_tool_call_id(String.t() | nil | term()) :: String.t()
  def sanitize_tool_call_id(id) when is_binary(id) and id != "" do
    if Regex.match?(~r/^[A-Za-z0-9_-]+$/, id), do: id, else: generate_safe_dispatch_id()
  end

  def sanitize_tool_call_id(_id), do: generate_safe_dispatch_id()

  @doc """
  Sanitize tool_call IDs across a list of tool calls.

  Returns the list with each tool_call's `:id` field replaced by its
  sanitized value. Called by `Agent.Loop.finalize_turn/3` before
  building the assistant message so that assistant `tool_calls[i].id`
  and tool result `tool_call_id` always match.
  """
  @spec sanitize_tool_call_ids([map()]) :: [map()]
  def sanitize_tool_call_ids(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, fn tc ->
      %{tc | id: sanitize_tool_call_id(tc[:id])}
    end)
  end

  @doc """
  Format a tool result for inclusion in the conversation history.
  """
  @spec format_tool_result(term()) :: String.t()
  def format_tool_result({:ok, result}), do: inspect(result)
  def format_tool_result({:error, reason}), do: "Error: #{inspect(reason)}"
  def format_tool_result(other), do: inspect(other)
end
