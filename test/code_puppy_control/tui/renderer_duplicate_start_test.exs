defmodule CodePuppyControl.TUI.RendererDuplicateStartTest do
  @moduledoc """
  Regression tests for the orphaned-spinner bug (exc-gate-stabilize).

  The bug: Streaming.build_stream_callback published `tool_call_start` on
  `%Event.ToolCallEnd{}` from the provider, duplicating the start event
  emitted by ToolDispatch.  The Renderer overwrote `spinner_ids[idx]`,
  losing the original Owl.Spinner ref — a later `ToolCallEnd` stopped
  only the latest spinner, leaving the first alive ("Sniffing around…").

  These tests use a SpyOutput adapter that records every `start_spinner/2`
  and `stop_spinner/1` call in an ETS table keyed by the Renderer's pid.
  This is strictly stronger than checking `spinners_idle?/1`, because the
  historical bug would leave renderer state idle while an Owl.Spinner
  process remained orphaned.
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.Stream.Event
  alias CodePuppyControl.TUI.Renderer

  # ── SpyOutput ────────────────────────────────────────────────────────────
  #
  # A test output_mod that records every `start_spinner/2` and `stop_spinner/1`
  # call into an ETS table keyed by the Renderer's pid.  `async: false` ensures
  # the test-process-owned ETS table is alive for the entire test lifecycle.

  @spy_table :renderer_spy_output

  defmodule SpyOutput do
    @moduledoc false
    @behaviour CodePuppyControl.TUI.Output

    @spy_table :renderer_spy_output

    @impl true
    def puts(_data), do: :ok

    @impl true
    def banner(_label, _color, _icon), do: :ok

    @impl true
    def tool_banner(_tool_name), do: :ok

    @impl true
    def start_spinner(loading_index, _idx) do
      ref = make_ref()
      record(:starts, ref)
      {ref, loading_index + 1}
    end

    @impl true
    def stop_spinner(ref) do
      record(:stops, ref)
      :ok
    end

    @impl true
    def stop_tool_spinner(spinner_ids, idx) do
      case Map.get(spinner_ids, idx) do
        nil ->
          spinner_ids

        ref ->
          record(:stops, ref)
          Map.delete(spinner_ids, idx)
      end
    end

    @impl true
    def stop_all_spinners(spinner_ids) do
      Enum.each(spinner_ids, fn {_idx, ref} -> record(:stops, ref) end)
      %{}
    end

    @impl true
    def color_background(:cyan), do: :cyan_background
    def color_background(_), do: :blue_background

    defp record(field, ref) do
      caller = self()

      case :ets.lookup(@spy_table, caller) do
        [{^caller, history}] ->
          updated = Map.update(history, field, [ref], &[ref | &1])
          :ets.insert(@spy_table, {caller, updated})

        [] ->
          :ok
      end
    end
  end

  # ── Setup ────────────────────────────────────────────────────────────────

  setup do
    # Create ETS table owned by test process (async: false → no races)
    if :ets.whereis(@spy_table) != :undefined do
      :ets.delete(@spy_table)
    end

    :ets.new(@spy_table, [:named_table, :public, :set])

    renderer_name = :"renderer_spy_test_#{System.unique_integer([:positive])}"

    {:ok, renderer_pid} =
      Renderer.start_link(name: renderer_name, output_mod: SpyOutput)

    # Pre-seed the spy entry for this renderer
    :ets.insert(@spy_table, {renderer_pid, %{starts: [], stops: []}})

    on_exit(fn ->
      if Process.alive?(renderer_pid), do: Renderer.stop(renderer_pid)
    end)

    {:ok, renderer_name: renderer_name, renderer_pid: renderer_pid}
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp spy_history(renderer_pid) do
    [{^renderer_pid, history}] = :ets.lookup(@spy_table, renderer_pid)
    # Reverse so events are in chronological order
    %{
      starts: Enum.reverse(history[:starts] || []),
      stops: Enum.reverse(history[:stops] || [])
    }
  end

  # ── Tests ─────────────────────────────────────────────────────────────────

  describe "duplicate ToolCallStart on same index" do
    test "start_spinner called exactly once, not twice", context do
      renderer = context.renderer_name
      renderer_pid = context.renderer_pid

      Renderer.push(renderer, %Event.ToolCallStart{index: 1, name: "read_file"})
      Renderer.push(renderer, %Event.ToolCallStart{index: 1, name: "read_file"})

      Process.sleep(20)

      history = spy_history(renderer_pid)

      # The core invariant: duplicate ToolCallStart must NOT cause a
      # second start_spinner call.  Before the fix, the renderer
      # overwrote spinner_ids[idx], starting two Owl spinners but
      # only tracking the second ref.
      assert length(history.starts) == 1,
             "Expected 1 start_spinner call, got #{length(history.starts)}: " <>
               "refs = #{inspect(history.starts)}"
    end

    test "duplicate start + single end: stop_spinner called for the original ref",
         context do
      renderer = context.renderer_name
      renderer_pid = context.renderer_pid

      Renderer.push(renderer, %Event.ToolCallStart{index: 2, name: "grep"})
      Renderer.push(renderer, %Event.ToolCallStart{index: 2, name: "grep"})

      Renderer.push(renderer, %Event.ToolCallEnd{
        index: 2,
        name: "grep",
        id: "tc-2",
        arguments: "{}"
      })

      Process.sleep(20)

      history = spy_history(renderer_pid)

      # One start, one stop
      assert length(history.starts) == 1
      assert length(history.stops) >= 1

      # The stopped ref must be the SAME ref that was started.
      # Before the fix, start_spinner returned ref1 then ref2,
      # but the renderer only stored ref2.  ToolCallEnd stopped
      # ref2, leaving ref1 orphaned.
      [started_ref] = history.starts

      assert started_ref in history.stops,
             "Started ref #{inspect(started_ref)} was never stopped. " <>
               "Stopped refs: #{inspect(history.stops)}"
    end

    test "tool_banner not re-printed on duplicate start (verified via no second spinner)",
         context do
      renderer = context.renderer_name
      renderer_pid = context.renderer_pid

      Renderer.push(renderer, %Event.ToolCallStart{index: 3, name: "list_files"})
      Renderer.push(renderer, %Event.ToolCallStart{index: 3, name: "list_files"})

      Renderer.push(renderer, %Event.ToolCallEnd{
        index: 3,
        name: "list_files",
        id: "tc-3",
        arguments: "{}"
      })

      Process.sleep(20)

      history = spy_history(renderer_pid)

      # Idempotent: only one spinner started
      assert length(history.starts) == 1

      # Spinner properly cleaned up
      assert Renderer.spinners_idle?(renderer)
    end

    test "single ToolCallStart/End (no duplicate) works normally", context do
      renderer = context.renderer_name
      renderer_pid = context.renderer_pid

      Renderer.push(renderer, %Event.ToolCallStart{index: 4, name: "run_shell_command"})

      Renderer.push(renderer, %Event.ToolCallEnd{
        index: 4,
        name: "run_shell_command",
        id: "tc-4",
        arguments: "{}"
      })

      Process.sleep(20)

      history = spy_history(renderer_pid)

      assert length(history.starts) == 1
      assert length(history.stops) >= 1

      [started_ref] = history.starts
      assert started_ref in history.stops

      assert Renderer.spinners_idle?(renderer)
    end

    test "two different indices get independent spinners", context do
      renderer = context.renderer_name
      renderer_pid = context.renderer_pid

      Renderer.push(renderer, %Event.ToolCallStart{index: 10, name: "read_file"})
      Renderer.push(renderer, %Event.ToolCallStart{index: 11, name: "grep"})

      Renderer.push(renderer, %Event.ToolCallEnd{
        index: 10,
        name: "read_file",
        id: "tc-10",
        arguments: "{}"
      })

      Renderer.push(renderer, %Event.ToolCallEnd{
        index: 11,
        name: "grep",
        id: "tc-11",
        arguments: "{}"
      })

      Process.sleep(20)

      history = spy_history(renderer_pid)

      assert length(history.starts) == 2
      assert length(history.stops) >= 2

      # Both started refs must be in stops
      for ref <- history.starts do
        assert ref in history.stops,
               "Ref #{inspect(ref)} was started but never stopped"
      end

      assert Renderer.spinners_idle?(renderer)
    end
  end
end
