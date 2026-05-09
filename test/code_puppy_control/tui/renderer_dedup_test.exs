defmodule CodePuppyControl.TUI.RendererDedupTest do
  @moduledoc """
  Regression tests for duplicate EventBus event delivery (code-puppy-szz).

  When a Renderer subscribes to both `session:<id>` and `run:<id>` PubSub
  topics, and EventBus broadcasts an event carrying both `run_id` and
  `session_id`, the Renderer receives the same event twice — once per
  topic.  Without dedup, text, thinking, status, and tool events are
  rendered twice, causing duplicate output, double token counts, and
  orphaned spinners.

  These tests verify that the Renderer's event dedup mechanism
  (seen_events / seen_events_queue) correctly suppresses duplicate
  delivery while preserving legitimate distinct events.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias CodePuppyControl.EventBus
  alias CodePuppyControl.Stream.Event
  alias CodePuppyControl.TUI.Renderer

  # ── SpyOutput ──────────────────────────────────────────────────────────
  #
  # Records output calls in an ETS table keyed by the Renderer's pid.
  # `async: false` ensures the test-process-owned ETS table is alive for
  # the entire test lifecycle.  This mirrors the pattern used in
  # RendererDuplicateStartTest.

  @spy_table :renderer_dedup_spy

  defmodule SpyOutput do
    @moduledoc false
    @behaviour CodePuppyControl.TUI.Output

    @spy_table :renderer_dedup_spy

    @impl true
    def puts(data) do
      record(:puts, data)
      :ok
    end

    @impl true
    def banner(label, color, icon) do
      record(:banners, {label, color, icon})
      :ok
    end

    @impl true
    def tool_banner(tool_name) do
      record(:tool_banners, tool_name)
      :ok
    end

    @impl true
    def start_spinner(loading_index, _idx) do
      record(:spinner_starts, loading_index)
      ref = make_ref()
      {ref, loading_index + 1}
    end

    @impl true
    def stop_spinner(_ref) do
      record(:spinner_stops, :ok)
      :ok
    end

    @impl true
    def stop_tool_spinner(spinner_ids, idx) do
      case Map.get(spinner_ids, idx) do
        nil -> spinner_ids
        _ref -> Map.delete(spinner_ids, idx)
      end
    end

    @impl true
    def stop_all_spinners(spinner_ids) do
      Enum.each(spinner_ids, fn {_idx, _ref} -> record(:spinner_stops, :ok) end)
      %{}
    end

    @impl true
    def color_background(:cyan), do: :cyan_background
    def color_background(_), do: :blue_background

    defp record(field, value) do
      caller = self()

      case :ets.lookup(@spy_table, caller) do
        [{^caller, history}] ->
          updated = Map.update(history, field, [value], &[value | &1])
          :ets.insert(@spy_table, {caller, updated})

        [] ->
          :ok
      end
    end
  end

  # ── CaptureOutput (for IO-assertion tests) ─────────────────────────────

  defmodule CaptureOutput do
    @moduledoc false
    @behaviour CodePuppyControl.TUI.Output

    alias CodePuppyControl.TUI.Renderer.OwlOutput

    @impl true
    def puts(data), do: OwlOutput.puts(data)

    @impl true
    def banner(label, color, icon), do: OwlOutput.banner(label, color, icon)

    @impl true
    def tool_banner(tool_name), do: OwlOutput.tool_banner(tool_name)

    @impl true
    def start_spinner(loading_index, _idx) do
      ref = make_ref()
      {ref, loading_index + 1}
    end

    @impl true
    def stop_spinner(_ref), do: :ok

    @impl true
    def stop_tool_spinner(spinner_ids, idx) do
      case Map.get(spinner_ids, idx) do
        nil -> spinner_ids
        _ref -> Map.delete(spinner_ids, idx)
      end
    end

    @impl true
    def stop_all_spinners(_spinner_ids), do: %{}

    @impl true
    def color_background(:cyan), do: :cyan_background
    def color_background(_), do: :blue_background
  end

  # ── Setup ────────────────────────────────────────────────────────────────

  setup do
    if :ets.whereis(@spy_table) != :undefined do
      :ets.delete(@spy_table)
    end

    :ets.new(@spy_table, [:named_table, :public, :set])

    session_id = "dedup-sess-#{System.unique_integer([:positive])}"
    run_id = "dedup-run-#{System.unique_integer([:positive])}"

    {:ok, session_id: session_id, run_id: run_id}
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp spy_history(renderer_pid) do
    [{^renderer_pid, history}] = :ets.lookup(@spy_table, renderer_pid)

    %{
      puts: Enum.reverse(history[:puts] || []),
      banners: Enum.reverse(history[:banners] || []),
      tool_banners: Enum.reverse(history[:tool_banners] || []),
      spinner_starts: Enum.reverse(history[:spinner_starts] || []),
      spinner_stops: Enum.reverse(history[:spinner_stops] || [])
    }
  end

  # Start a Renderer subscribed to both session and run topics (the
  # configuration that triggers duplicate delivery).
  defp start_dual_sub_renderer(session_id, run_id) do
    name = :"renderer_dedup_dual_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Renderer.start_link(
        name: name,
        session_id: session_id,
        run_id: run_id,
        output_mod: SpyOutput
      )

    # Seed spy entry
    :ets.insert(
      @spy_table,
      {pid, %{puts: [], banners: [], tool_banners: [], spinner_starts: [], spinner_stops: []}}
    )

    {pid, name}
  end

  # Start a Renderer subscribed to only the session topic (control group:
  # no duplicates possible from EventBus dual broadcast).
  defp start_session_only_renderer(session_id) do
    name = :"renderer_dedup_sess_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Renderer.start_link(
        name: name,
        session_id: session_id,
        output_mod: SpyOutput
      )

    :ets.insert(
      @spy_table,
      {pid, %{puts: [], banners: [], tool_banners: [], spinner_starts: [], spinner_stops: []}}
    )

    {pid, name}
  end

  # ── Tests: Direct duplicate delivery via send ────────────────────────────
  #
  # Simulates the duplicate by directly sending the same event twice
  # to the Renderer's handle_info.  This is deterministic and doesn't
  # depend on PubSub timing.

  describe "handle_info dedup — direct send" do
    test "same event sent twice is processed only once", context do
      session_id = context.session_id
      run_id = context.run_id
      {pid, _name} = start_dual_sub_renderer(session_id, run_id)

      event = %{
        type: "status",
        status: "thinking",
        run_id: run_id,
        session_id: session_id,
        timestamp: DateTime.utc_now()
      }

      # Send the same event twice (simulating dual-topic delivery)
      send(pid, {:event, event})
      send(pid, {:event, event})

      Process.sleep(50)

      history = spy_history(pid)
      # Status events go through handle_eventbus_event which calls puts
      # Without dedup, we'd see 2 puts; with dedup, only 1
      assert length(history.puts) == 1,
             "Expected 1 puts for deduplicated status event, got #{length(history.puts)}"

      Renderer.stop(pid)
    end

    test "distinct events are both processed", context do
      session_id = context.session_id
      run_id = context.run_id
      {pid, _name} = start_dual_sub_renderer(session_id, run_id)

      event1 = %{
        type: "status",
        status: "step-1",
        run_id: run_id,
        session_id: session_id,
        timestamp: DateTime.utc_now()
      }

      event2 = %{
        type: "status",
        status: "step-2",
        run_id: run_id,
        session_id: session_id,
        timestamp: DateTime.utc_now()
      }

      send(pid, {:event, event1})
      send(pid, {:event, event2})

      Process.sleep(50)

      history = spy_history(pid)
      # Two distinct events → 2 puts
      assert length(history.puts) == 2,
             "Expected 2 puts for distinct events, got #{length(history.puts)}"

      Renderer.stop(pid)
    end
  end

  # ── Tests: EventBus PubSub duplicate delivery ───────────────────────────
  #
  # These broadcast via EventBus and verify that the Renderer only
  # processes each event once, even though it's subscribed to both
  # the session and run topics.

  describe "EventBus PubSub dedup — dual subscription" do
    test "text event broadcast with both IDs renders only once", context do
      session_id = context.session_id
      run_id = context.run_id
      {pid, _name} = start_dual_sub_renderer(session_id, run_id)

      # Broadcast a text event — EventBus sends to both run and session topics
      EventBus.broadcast_text(run_id, session_id, "hello world\n",
        chunk: false,
        store: false
      )

      Process.sleep(100)

      history = spy_history(pid)
      # Without dedup, text events from EventBus would be processed twice
      # (once from session topic, once from run topic).
      # With dedup, only once.
      assert length(history.puts) == 1,
             "Expected 1 puts for deduplicated text event, got #{length(history.puts)}"

      Renderer.stop(pid)
    end

    test "status event broadcast with both IDs renders only once", context do
      session_id = context.session_id
      run_id = context.run_id
      {pid, _name} = start_dual_sub_renderer(session_id, run_id)

      EventBus.broadcast_status(run_id, session_id, "agent_response",
        metadata: %{banner: true},
        store: false
      )

      Process.sleep(100)

      history = spy_history(pid)
      # Status events render via handle_eventbus_event
      assert length(history.puts) <= 1,
             "Status event rendered more than once: #{length(history.puts)} puts"

      Renderer.stop(pid)
    end

    test "tool_call event broadcast with both IDs renders only once", context do
      session_id = context.session_id
      run_id = context.run_id
      {pid, _name} = start_dual_sub_renderer(session_id, run_id)

      EventBus.broadcast_tool_call(run_id, session_id, "read_file", %{},
        tool_call_id: "tc-1",
        store: false
      )

      Process.sleep(100)

      history = spy_history(pid)
      # Tool call events may be converted to canonical ToolCallStart or
      # handled as legacy.  Either way, dedup should prevent double rendering.
      assert length(history.tool_banners) <= 1,
             "Tool banner printed more than once: #{length(history.tool_banners)}"

      Renderer.stop(pid)
    end

    test "thinking event broadcast with both IDs renders only once", context do
      session_id = context.session_id
      run_id = context.run_id
      {pid, _name} = start_dual_sub_renderer(session_id, run_id)

      EventBus.broadcast_thinking(run_id, session_id, "hmm...", store: false)

      Process.sleep(100)

      history = spy_history(pid)
      # Thinking events render via handle_eventbus_event
      assert length(history.puts) <= 1,
             "Thinking event rendered more than once: #{length(history.puts)} puts"

      Renderer.stop(pid)
    end

    test "multiple distinct events all render (no false suppression)", context do
      session_id = context.session_id
      run_id = context.run_id
      {pid, _name} = start_dual_sub_renderer(session_id, run_id)

      EventBus.broadcast_text(run_id, session_id, "first line\n",
        chunk: false,
        store: false
      )

      # Small sleep to let distinct events get different timestamps
      Process.sleep(10)

      EventBus.broadcast_text(run_id, session_id, "second line\n",
        chunk: false,
        store: false
      )

      Process.sleep(100)

      history = spy_history(pid)
      # Both distinct events should render (2 puts), not be suppressed
      assert length(history.puts) == 2,
             "Expected 2 puts for distinct text events, got #{length(history.puts)}"

      Renderer.stop(pid)
    end
  end

  # ── Tests: Session-only subscription (no duplicates) ────────────────────

  describe "single topic subscription — no duplicates possible" do
    test "events rendered exactly once with session-only subscription", context do
      session_id = context.session_id
      run_id = context.run_id
      {pid, _name} = start_session_only_renderer(session_id)

      # Broadcast with both IDs, but Renderer is only on session topic
      EventBus.broadcast_text(run_id, session_id, "hello\n",
        chunk: false,
        store: false
      )

      Process.sleep(100)

      history = spy_history(pid)

      assert length(history.puts) == 1,
             "Session-only: expected 1 puts, got #{length(history.puts)}"

      Renderer.stop(pid)
    end
  end

  # ── Tests: Dedup state is properly reset ────────────────────────────────

  describe "dedup state reset" do
    test "reset clears dedup state so re-broadcast events render again", context do
      session_id = context.session_id
      run_id = context.run_id
      {pid, name} = start_dual_sub_renderer(session_id, run_id)

      # First broadcast
      EventBus.broadcast_text(run_id, session_id, "first\n",
        chunk: false,
        store: false
      )

      Process.sleep(50)

      # Reset the renderer — clears dedup state
      Renderer.reset(name)

      # Re-seed spy entry (pid unchanged after reset)
      :ets.insert(
        @spy_table,
        {pid, %{puts: [], banners: [], tool_banners: [], spinner_starts: [], spinner_stops: []}}
      )

      # Same content broadcast again should NOT be suppressed
      # (dedup was cleared by reset)
      EventBus.broadcast_text(run_id, session_id, "first\n",
        chunk: false,
        store: false
      )

      Process.sleep(50)

      history = spy_history(pid)

      assert length(history.puts) == 1,
             "After reset, same event should render (not be deduped)"

      Renderer.stop(pid)
    end

    test "dedup survives many distinct events without unbounded growth", context do
      session_id = context.session_id
      run_id = context.run_id
      {pid, _name} = start_dual_sub_renderer(session_id, run_id)

      # Send more distinct events than @dedup_cap (256)
      for i <- 0..300 do
        send(
          pid,
          {:event, %{type: "status", status: "step-#{i}", run_id: run_id, session_id: session_id}}
        )
      end

      Process.sleep(100)

      # Renderer should still be alive and responsive
      assert Process.alive?(pid)

      # Verify renderer responds to query API (not stuck)
      assert Renderer.token_count(pid) == 0

      Renderer.stop(pid)
    end
  end

  # ── Tests: Direct push is NOT deduped ────────────────────────────────────
  #
  # Renderer.push/2 goes through handle_cast, not handle_info.
  # Dedup only applies to handle_info (PubSub events).

  describe "direct push bypasses dedup" do
    test "push events are always rendered, never deduped", context do
      session_id = context.session_id
      {pid, name} = start_session_only_renderer(session_id)

      Renderer.push(name, %Event.TextStart{index: 0})
      Renderer.push(name, %Event.TextDelta{index: 0, text: "hello\n"})
      Renderer.push(name, %Event.TextDelta{index: 0, text: "world\n"})
      Renderer.push(name, %Event.TextEnd{index: 0})

      Process.sleep(20)

      # Two deltas → token_count of 2 (not deduped)
      assert Renderer.token_count(name) == 2

      Renderer.stop(pid)
    end
  end

  # ── Tests: Capture IO for text-level dedup verification ─────────────────

  describe "capture_io — text dedup" do
    test "duplicate text event does not produce duplicate output", context do
      session_id = context.session_id
      run_id = context.run_id

      output =
        capture_io(fn ->
          name = :"renderer_dedup_io_#{System.unique_integer([:positive])}"

          {:ok, pid} =
            Renderer.start_link(
              name: name,
              session_id: session_id,
              run_id: run_id,
              output_mod: CaptureOutput
            )

          EventBus.broadcast_text(run_id, session_id, "unique message text\n",
            chunk: false,
            store: false
          )

          Process.sleep(100)

          Renderer.finalize(name)
          Process.sleep(10)
          Renderer.stop(pid)
        end)

      # Count occurrences of the unique text in output
      occurrences =
        output
        |> String.split("unique message text")
        |> length()
        |> Kernel.-(1)

      # Should appear exactly once, not twice
      assert occurrences == 1,
             "Expected 'unique message text' to appear once, but appeared #{occurrences} times"
    end
  end
end
