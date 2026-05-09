defmodule CodePuppyControl.Agent.Loop.StreamingTest do
  @moduledoc """
  Regression tests for Streaming.build_stream_callback/1.

  The orphaned-spinner bug was caused by the stream callback publishing
  `agent_tool_call_start` when receiving `%Event.ToolCallEnd{}` from the
  provider — duplicating the start event emitted by ToolDispatch.  These
  tests verify that:

    1. `{:stream, %Event.ToolCallEnd{}}` does NOT publish lifecycle events.
    2. `{:stream, %Event.TextDelta{}}` still publishes `agent_llm_stream`.
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.Agent.Loop.Streaming
  alias CodePuppyControl.EventBus
  alias CodePuppyControl.Stream.Event

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

  describe "build_stream_callback/1" do
    setup do
      run_id = "streaming-test-#{System.unique_integer([:positive])}"
      session_id = "streaming-sess-#{System.unique_integer([:positive])}"

      :ok = EventBus.subscribe_run(run_id)

      state = %{run_id: run_id, session_id: session_id}

      {:ok, state: state, run_id: run_id}
    end

    test "ToolCallEnd from provider does NOT publish agent_tool_call_start", %{
      state: state
    } do
      callback = Streaming.build_stream_callback(state)

      # Simulate the provider stream event that was the root cause:
      # the model finished emitting a tool-call block.
      callback.({:stream, %Event.ToolCallEnd{id: "tc-1", name: "read_file", arguments: "{}"}})

      events = collect_events(200)

      tool_start_events =
        Enum.filter(events, fn e -> e[:type] == "agent_tool_call_start" end)

      tool_end_events =
        Enum.filter(events, fn e -> e[:type] == "agent_tool_call_end" end)

      assert tool_start_events == [],
             "Expected NO agent_tool_call_start from ToolCallEnd stream event, " <>
               "got #{length(tool_start_events)}: #{inspect(Enum.map(events, & &1[:type]))}"

      assert tool_end_events == [],
             "Expected NO agent_tool_call_end from ToolCallEnd stream event, " <>
               "got #{length(tool_end_events)}: #{inspect(Enum.map(events, & &1[:type]))}"
    end

    test "TextDelta from provider still publishes agent_llm_stream", %{
      state: state
    } do
      callback = Streaming.build_stream_callback(state)

      callback.({:stream, %Event.TextDelta{text: "Hello world"}})

      events = collect_events(200)

      stream_events =
        Enum.filter(events, fn e -> e[:type] == "agent_llm_stream" end)

      assert length(stream_events) >= 1,
             "Expected at least one agent_llm_stream event, " <>
               "got: #{inspect(Enum.map(events, & &1[:type]))}"

      [stream_ev] = Enum.take(stream_events, 1)
      assert stream_ev[:chunk] == "Hello world"
    end

    test "Done from provider does not publish lifecycle events", %{state: state} do
      callback = Streaming.build_stream_callback(state)

      callback.({:stream, %Event.Done{}})

      events = collect_events(200)

      # Done should not emit any tool-call or turn lifecycle events
      event_types = Enum.map(events, & &1[:type])

      refute "agent_tool_call_start" in event_types
      refute "agent_tool_call_end" in event_types
      refute "agent_turn_started" in event_types
    end

    test "unknown stream events are silently ignored", %{state: state} do
      callback = Streaming.build_stream_callback(state)

      # Should not crash
      callback.({:stream, {:something_unexpected, "data"}})
      callback.({:other, "not a stream tuple"})

      events = collect_events(200)

      # No events published for unknown inputs
      assert events == []
    end
  end
end
