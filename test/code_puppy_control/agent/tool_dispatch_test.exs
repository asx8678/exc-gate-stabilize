defmodule CodePuppyControl.Agent.ToolDispatchTest do
  @moduledoc """
  Unit tests for ToolDispatch: ID sanitization, name resolution,
  and event lifecycle balance (tool_call_start + tool_call_end).
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.Agent.Loop.ToolDispatch
  alias CodePuppyControl.EventBus

  @valid_chars ~r/^[A-Za-z0-9_-]+$/

  describe "sanitize_tool_call_id/1" do
    test "passes through valid IDs unchanged" do
      assert ToolDispatch.sanitize_tool_call_id("call_abc123") == "call_abc123"
    end

    test "passes through IDs with dashes and underscores" do
      id = "call_my-tool_v2"
      assert ToolDispatch.sanitize_tool_call_id(id) == id
    end

    test "replaces empty string with generated ID" do
      result = ToolDispatch.sanitize_tool_call_id("")
      assert result != ""
      assert Regex.match?(@valid_chars, result)
    end

    test "replaces nil with generated ID" do
      result = ToolDispatch.sanitize_tool_call_id(nil)
      assert result != ""
      assert Regex.match?(@valid_chars, result)
    end

    test "replaces ID with invalid characters (dots)" do
      result = ToolDispatch.sanitize_tool_call_id("call.123")
      assert result != "call.123"
      assert Regex.match?(@valid_chars, result)
    end

    test "replaces ID with invalid characters (colons, slashes)" do
      result = ToolDispatch.sanitize_tool_call_id("abc:def/ghi")
      assert result != "abc:def/ghi"
      refute result =~ ":"
      refute result =~ "/"
      assert Regex.match?(@valid_chars, result)
    end

    test "generates unique IDs for repeated calls with nil input" do
      ids = Enum.map(1..10, fn _ -> ToolDispatch.sanitize_tool_call_id(nil) end)
      assert length(Enum.uniq(ids)) == 10, "Generated IDs must be unique"
    end
  end

  describe "sanitize_tool_call_ids/1" do
    test "sanitizes list of tool calls with mixed valid and invalid IDs" do
      tool_calls = [
        %{id: "valid_id", name: :tool_a, arguments: %{}},
        %{id: "", name: :tool_b, arguments: %{}},
        %{id: "bad.chars", name: :tool_c, arguments: %{}}
      ]

      result = ToolDispatch.sanitize_tool_call_ids(tool_calls)

      assert length(result) == 3

      # First: valid, unchanged
      assert Enum.at(result, 0).id == "valid_id"

      # Second: empty → generated
      id2 = Enum.at(result, 1).id
      assert id2 != ""
      assert Regex.match?(@valid_chars, id2)

      # Third: invalid chars → generated
      id3 = Enum.at(result, 2).id
      assert id3 != "bad.chars"
      assert Regex.match?(@valid_chars, id3)
    end

    test "returns empty list for empty input" do
      assert ToolDispatch.sanitize_tool_call_ids([]) == []
    end

    test "preserves name and arguments fields" do
      tool_calls = [%{id: "", name: :echo_tool, arguments: %{"input" => "hello"}}]

      [result] = ToolDispatch.sanitize_tool_call_ids(tool_calls)

      assert result.name == :echo_tool
      assert result.arguments == %{"input" => "hello"}
      assert Regex.match?(@valid_chars, result.id)
    end
  end

  # ── Event Lifecycle Balance ────────────────────────────────────────────────

  describe "dispatch_tool_calls/3 event lifecycle" do
    @describetag :capture_log

    # Minimal agent module for testing — only echo_tool is allowed
    defmodule AllowedAgent do
      @behaviour CodePuppyControl.Agent.Behaviour

      @impl true
      def name, do: :allowed_test_agent

      @impl true
      def system_prompt(_ctx), do: "test"

      @impl true
      def allowed_tools, do: [:echo_tool]

      @impl true
      def model_preference, do: "test-model"

      @impl true
      def on_tool_result(_tool, _result, state), do: {:cont, state}
    end

    defp collect_events(timeout) do
      collect_events([], timeout)
    end

    defp collect_events(acc, timeout) do
      receive do
        {:event, event} -> collect_events([event | acc], timeout)
      after
        timeout -> Enum.reverse(acc)
      end
    end

    setup do
      run_id = "dispatch-test-#{System.unique_integer([:positive])}"
      session_id = "dispatch-sess-#{System.unique_integer([:positive])}"

      :ok = EventBus.subscribe_run(run_id)

      state = %{
        run_id: run_id,
        session_id: session_id,
        agent_module: AllowedAgent,
        agent_state: %{}
      }

      {:ok, state: state, run_id: run_id}
    end

    test "allowed tool emits exactly one start and one end event", %{state: state} do
      turn = %{
        pending_tool_calls: [
          %{id: "tc-allowed-1", name: :echo_tool, arguments: %{"input" => "hi"}}
        ]
      }

      messages = []

      ToolDispatch.dispatch_tool_calls(state, turn, messages)

      events = collect_events(500)

      start_events =
        Enum.filter(events, fn e -> e[:type] == "agent_tool_call_start" end)

      end_events =
        Enum.filter(events, fn e -> e[:type] == "agent_tool_call_end" end)

      assert length(start_events) == 1,
             "Expected 1 agent_tool_call_start, got #{length(start_events)}: #{inspect(Enum.map(events, & &1[:type]))}"

      assert length(end_events) == 1,
             "Expected 1 agent_tool_call_end, got #{length(end_events)}: #{inspect(Enum.map(events, & &1[:type]))}"

      # Start and end share the same tool_call_id
      [start_ev] = start_events
      [end_ev] = end_events
      assert start_ev[:tool_call_id] == end_ev[:tool_call_id]
      assert start_ev[:tool_name] == "echo_tool"
    end

    test "disallowed tool emits balanced start and end events", %{state: state} do
      turn = %{
        pending_tool_calls: [
          %{id: "tc-disallowed-1", name: "evil_tool", arguments: %{}}
        ]
      }

      messages = []

      result_messages = ToolDispatch.dispatch_tool_calls(state, turn, messages)

      events = collect_events(500)

      start_events =
        Enum.filter(events, fn e -> e[:type] == "agent_tool_call_start" end)

      end_events =
        Enum.filter(events, fn e -> e[:type] == "agent_tool_call_end" end)

      assert length(start_events) == 1,
             "Expected 1 agent_tool_call_start for disallowed tool, got #{length(start_events)}: #{inspect(Enum.map(events, & &1[:type]))}"

      assert length(end_events) == 1,
             "Expected 1 agent_tool_call_end for disallowed tool, got #{length(end_events)}: #{inspect(Enum.map(events, & &1[:type]))}"

      [start_ev] = start_events
      [end_ev] = end_events
      assert start_ev[:tool_call_id] == end_ev[:tool_call_id]
      assert end_ev[:result] == {:error, :tool_not_allowed}

      # The result message must use the same sanitized tool_call_id
      # as the start/end events.
      [result_msg] = result_messages
      assert result_msg[:role] == "tool"

      assert result_msg[:tool_call_id] == start_ev[:tool_call_id],
             "Result message tool_call_id #{inspect(result_msg[:tool_call_id])} != " <>
               "event tool_call_id #{inspect(start_ev[:tool_call_id])}"

      assert result_msg[:content] =~ "not available"
    end

    test "mixed allowed and disallowed tools emit balanced start/end pairs", %{
      state: state
    } do
      turn = %{
        pending_tool_calls: [
          %{id: "tc-mix-1", name: :echo_tool, arguments: %{"input" => "ok"}},
          %{id: "tc-mix-2", name: "no_such_tool", arguments: %{}}
        ]
      }

      messages = []

      result_messages = ToolDispatch.dispatch_tool_calls(state, turn, messages)

      events = collect_events(500)

      start_events =
        Enum.filter(events, fn e -> e[:type] == "agent_tool_call_start" end)

      end_events =
        Enum.filter(events, fn e -> e[:type] == "agent_tool_call_end" end)

      # 2 starts and 2 ends — balanced lifecycle for every tool call
      assert length(start_events) == 2,
             "Expected 2 agent_tool_call_start, got #{length(start_events)}: #{inspect(Enum.map(events, & &1[:type]))}"

      assert length(end_events) == 2,
             "Expected 2 agent_tool_call_end, got #{length(end_events)}: #{inspect(Enum.map(events, & &1[:type]))}"

      # Each start has a matching end by tool_call_id
      start_ids = MapSet.new(start_events, & &1[:tool_call_id])
      end_ids = MapSet.new(end_events, & &1[:tool_call_id])
      assert MapSet.equal?(start_ids, end_ids)

      # Result messages must use the same tool_call_ids as events.
      # The disallowed tool (tc-mix-2) gets a sanitized id because
      # its original string name won't resolve to an allowed atom.
      result_msg_ids =
        result_messages
        |> Enum.filter(&(&1[:role] == "tool"))
        |> MapSet.new(& &1[:tool_call_id])

      assert MapSet.equal?(start_ids, result_msg_ids),
             "Result message IDs #{inspect(result_msg_ids)} != event IDs #{inspect(start_ids)}"
    end
  end
end
