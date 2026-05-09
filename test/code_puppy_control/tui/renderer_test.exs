defmodule CodePuppyControl.TUI.RendererTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias CodePuppyControl.Stream.Event
  alias CodePuppyControl.TUI.Renderer

  # ── No-op output adapter for spinner-idempotency & state-only tests ─────
  #
  # Returns valid spinner refs without starting real Owl spinners.
  # The Renderer's own query API (spinners_idle?, spinner_active?) is
  # sufficient for smoke-testing idempotency. For full spy coverage that
  # counts start_spinner/stop_spinner calls, see RendererDuplicateStartTest.
  #
  # Discards all output. For a test adapter that preserves IO output
  # (compatible with capture_io), see CaptureOutput below.

  defmodule NoOpOutput do
    @moduledoc false
    @behaviour CodePuppyControl.TUI.Output

    @impl true
    def puts(_data), do: :ok

    @impl true
    def banner(_label, _color, _icon), do: :ok

    @impl true
    def tool_banner(_tool_name), do: :ok

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

  # ── Capture output adapter for IO-assertion tests ─────────────────────
  #
  # Delegates rendering (puts, banner, tool_banner) to OwlOutput so that
  # output is captured by ExUnit.CaptureIO, but uses make_ref() for spinner
  # refs instead of starting real Owl.Spinner processes.
  #
  # ROOT CAUSE (code-puppy-268): Owl.Spinner.stop/1 calls
  # Owl.LiveScreen.await_render/1, which does an unbounded `receive` for a
  # `:rendered` message.  When Owl.LiveScreen is not running (it returns
  # `:ignore` from init when there's no terminal, e.g. in CI), the cast is
  # silently dropped and await_render blocks forever.  The GenServer.call
  # inside Owl.Spinner.stop eventually times out (default 5000ms), but that
  # blocks the Renderer GenServer for the entire duration, causing cascading
  # GenServer.call timeouts on finalize/reset.
  #
  # By avoiding real Owl.Spinner processes entirely, this adapter eliminates
  # the dependency on Owl.LiveScreen availability and makes tests
  # deterministic regardless of terminal presence.

  defmodule CaptureOutput do
    @moduledoc false
    @behaviour CodePuppyControl.TUI.Output

    alias CodePuppyControl.TUI.Renderer.OwlOutput

    # ── Rendering: delegate to OwlOutput (writes to :stdio, captured by capture_io) ──

    @impl true
    def puts(data), do: OwlOutput.puts(data)

    @impl true
    def banner(label, color, icon), do: OwlOutput.banner(label, color, icon)

    @impl true
    def tool_banner(tool_name), do: OwlOutput.tool_banner(tool_name)

    # ── Spinners: synthetic refs, no real Owl.Spinner processes ──────────

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

  # ── Helpers ────────────────────────────────────────────────────────────────

  # Starts a renderer without PubSub subscriptions (no session/run id).
  # We push events directly via Renderer.push/2.
  #
  # Defaults to NoOpOutput to avoid real Owl.Spinner processes, which depend
  # on Owl.LiveScreen and cause GenServer.call timeout flakes when no
  # terminal is available (see CaptureOutput docs / code-puppy-268).
  defp start_renderer(opts \\ []) do
    # Use a unique name so parallel tests don't clash
    name =
      Keyword.get_lazy(opts, :name, fn ->
        :"renderer_test_#{System.unique_integer([:positive])}"
      end)

    opts = Keyword.put_new(opts, :output_mod, NoOpOutput)
    {:ok, pid} = Renderer.start_link(opts ++ [name: name])
    {pid, name}
  end

  # Runs a full renderer lifecycle inside CaptureIO and returns the
  # captured stdout.  Starting the GenServer *inside* capture_io
  # ensures its group leader is the captured device, so all
  # Owl.IO.puts output is captured.
  #
  # Always uses CaptureOutput, which delegates rendering to OwlOutput
  # (output captured by capture_io) but avoids real Owl.Spinner processes
  # that depend on Owl.LiveScreen (see code-puppy-268).
  defp capture_renderer(opts \\ [], fun) do
    # Force CaptureOutput — callers must not override this, as the
    # assertions depend on IO output being captured.
    opts = Keyword.put(opts, :output_mod, CaptureOutput)

    capture_io(fn ->
      {pid, name} = start_renderer(opts)
      fun.(name)
      # Small sleep ensures elapsed > 0 for the completion stats line.
      # (No longer needed for Owl.Spinner teardown since CaptureOutput
      # uses synthetic refs, but kept for elapsed-time stability.)
      Process.sleep(10)
      Renderer.finalize(name)
      Process.sleep(10)
      Renderer.stop(pid)
    end)
  end

  # ── Lifecycle ──────────────────────────────────────────────────────────────

  describe "start_link/1" do
    test "starts without session_id or run_id" do
      {pid, _name} = start_renderer()
      assert Process.alive?(pid)
      Renderer.stop(pid)
    end

    test "starts with a session_id" do
      {pid, _name} = start_renderer(session_id: "test-session-1")
      assert Process.alive?(pid)
      Renderer.stop(pid)
    end

    test "starts with a run_id" do
      {pid, _name} = start_renderer(run_id: "test-run-1")
      assert Process.alive?(pid)
      Renderer.stop(pid)
    end
  end

  # ── Text Streaming ─────────────────────────────────────────────────────────

  describe "TextStart / TextDelta / TextEnd" do
    test "TextStart prints AGENT RESPONSE banner" do
      output =
        capture_renderer(fn name ->
          Renderer.push(name, %Event.TextStart{index: 0})
          Renderer.push(name, %Event.TextDelta{index: 0, text: "body\n"})
          Renderer.push(name, %Event.TextEnd{index: 0})
        end)

      assert output =~ "AGENT RESPONSE"
    end

    test "TextDelta renders text and finalizes with token stats" do
      long_text = String.duplicate("x", 25) <> "\n"

      output =
        capture_renderer(fn name ->
          Renderer.push(name, %Event.TextStart{index: 0})
          Renderer.push(name, %Event.TextDelta{index: 0, text: long_text})
          Renderer.push(name, %Event.TextEnd{index: 0})
        end)

      assert output =~ "Completed:"
      assert output =~ "tokens"
    end

    test "TextEnd flushes remaining buffer" do
      output =
        capture_renderer(fn name ->
          Renderer.push(name, %Event.TextStart{index: 0})
          # "hello" is short (5 chars) — stays buffered until TextEnd flushes it
          Renderer.push(name, %Event.TextDelta{index: 0, text: "hello"})
          Renderer.push(name, %Event.TextEnd{index: 0})
        end)

      assert output =~ "hello"
    end
  end

  # ── Tool Call Flow ─────────────────────────────────────────────────────────

  describe "ToolCallStart / ToolCallEnd" do
    test "ToolCallStart prints tool banner" do
      output =
        capture_renderer(fn name ->
          Renderer.push(name, %Event.ToolCallStart{index: 1, name: "read_file"})

          Renderer.push(name, %Event.ToolCallEnd{
            index: 1,
            name: "read_file",
            id: "tc-1",
            arguments: "{}"
          })
        end)

      assert output =~ "READ FILE"
    end

    test "ToolCallEnd prints completion marker" do
      output =
        capture_renderer(fn name ->
          Renderer.push(name, %Event.ToolCallStart{index: 1, name: "read_file"})

          Renderer.push(name, %Event.ToolCallEnd{
            index: 1,
            name: "read_file",
            id: "tc-1",
            arguments: "{}"
          })
        end)

      assert output =~ "read_file"
    end

    test "unknown tool name prints default-style banner" do
      output =
        capture_renderer(fn name ->
          Renderer.push(name, %Event.ToolCallStart{index: 2, name: "custom_tool_xyz"})

          Renderer.push(name, %Event.ToolCallEnd{
            index: 2,
            name: "custom_tool_xyz",
            id: "tc-2",
            arguments: "{}"
          })
        end)

      # Banner contains the tool name (as its own label for unknown tools)
      assert output =~ "custom_tool_xyz"
    end
  end

  # ── Thinking Flow ──────────────────────────────────────────────────────────

  describe "ThinkingStart / ThinkingDelta / ThinkingEnd" do
    test "thinking flow renders thinking text" do
      output =
        capture_renderer(fn name ->
          Renderer.push(name, %Event.ThinkingStart{index: 3})
          Renderer.push(name, %Event.ThinkingDelta{index: 3, text: "hmm..."})
          Renderer.push(name, %Event.ThinkingEnd{index: 3})
        end)

      assert output =~ "THINKING"
      assert output =~ "hmm..."
    end
  end

  # ── Done Event ─────────────────────────────────────────────────────────────

  describe "Done event" do
    test "flushes partial text buffers" do
      output =
        capture_renderer(fn name ->
          Renderer.push(name, %Event.TextStart{index: 0})
          # "partial" is short — stays buffered until Done or finalize flushes
          Renderer.push(name, %Event.TextDelta{index: 0, text: "partial"})
          Renderer.push(name, %Event.ToolCallStart{index: 1, name: "grep"})
          Renderer.push(name, %Event.Done{})
        end)

      assert output =~ "partial"
    end
  end

  # ── EventBus Map Events ───────────────────────────────────────────────────

  describe "EventBus map events" do
    test "converts agent_llm_stream to rendered text" do
      # EventBus events use atom keys (legacy format)
      long_chunk = String.duplicate("x", 25) <> "\n"

      output =
        capture_renderer(fn name ->
          Renderer.push(name, %Event.TextStart{index: 0})
          send(name, {:event, %{type: "agent_llm_stream", chunk: long_chunk}})
        end)

      # The text should appear in the output (flushed via finalize)
      assert output =~ String.duplicate("x", 25)
    end

    test "handles agent_run_failed event" do
      {pid, _name} = start_renderer()

      # Should not crash even for unrecognized events
      send(pid, {:event, %{"type" => "agent_run_failed", "error" => "timeout"}})

      Process.sleep(10)
      assert Process.alive?(pid)

      Renderer.stop(pid)
    end

    test "handles agent_run_completed as Done" do
      output =
        capture_renderer(fn name ->
          Renderer.push(name, %Event.TextStart{index: 0})
          Renderer.push(name, %Event.TextDelta{index: 0, text: "some text\n"})
          send(name, {:event, %{type: "agent_run_completed"}})
        end)

      # Text should have been flushed
      assert output =~ "some text"
    end

    test "ignores unknown event types" do
      {pid, _name} = start_renderer()

      send(pid, {:event, %{"type" => "something_weird", "data" => "nope"}})

      Process.sleep(10)
      assert Process.alive?(pid)

      Renderer.stop(pid)
    end
  end

  # ── Finalize and Reset ────────────────────────────────────────────────────

  describe "finalize/1" do
    test "renders buffered text and prints completion stats" do
      output =
        capture_renderer(fn name ->
          Renderer.push(name, %Event.TextStart{index: 0})
          Renderer.push(name, %Event.TextDelta{index: 0, text: "hello world\n"})
        end)

      assert output =~ "hello world"
      assert output =~ "Completed:"
    end
  end

  describe "reset/1" do
    # Reset tests the public API — state assertions are legitimate here
    # per issue guidance (reset is about internal state cleanup).
    test "clears state for a new session" do
      {pid, name} = start_renderer()

      Renderer.push(name, %Event.TextStart{index: 0})
      Renderer.push(name, %Event.TextDelta{index: 0, text: "some text\n"})
      Renderer.push(name, %Event.ToolCallStart{index: 1, name: "grep"})

      Process.sleep(50)

      :ok = Renderer.reset(name)

      # Verify all previously-active indices are cleared
      refute Renderer.streaming?(name, 0)
      refute Renderer.text_part?(name, 0)
      refute Renderer.tool_part?(name, 1)
      refute Renderer.banner_printed?(name, 0)

      # Verify spinners and buffers are clean
      assert Renderer.spinners_idle?(name)
      assert Renderer.all_buffers_flushed?(name)
      assert Renderer.token_count(name) == 0

      Renderer.stop(pid)
    end
  end

  # ── child_spec ─────────────────────────────────────────────────────────────

  describe "child_spec/1" do
    test "returns a valid child spec for a supervisor" do
      spec = Renderer.child_spec(session_id: "sess-1")

      assert spec.id == CodePuppyControl.TUI.Renderer

      assert spec.start ==
               {CodePuppyControl.TUI.Renderer, :start_link, [[session_id: "sess-1"]]}

      # Should be restartable
      assert spec.restart == :transient
    end

    test "supports custom id via :id option" do
      spec = Renderer.child_spec(id: :my_renderer, session_id: "sess-2")
      assert spec.id == :my_renderer
    end
  end

  # ── Duplicate ToolCallStart (orphaned-spinner regression) ─────────────────
  #
  # These tests verify internal renderer state (spinners_idle?, spinner_active?)
  # as a fast smoke test.  For stronger regression coverage that verifies
  # start_spinner/stop_spinner call counts and ref identity, see
  # RendererDuplicateStartTest in renderer_duplicate_start_test.exs.

  describe "duplicate ToolCallStart on same index" do
    setup do
      renderer_name =
        :"renderer_dup_test_#{System.unique_integer([:positive])}"

      {:ok, renderer_pid} =
        Renderer.start_link(
          name: renderer_name,
          output_mod: NoOpOutput
        )

      on_exit(fn ->
        if Process.alive?(renderer_pid), do: Renderer.stop(renderer_pid)
      end)

      {:ok, renderer_name: renderer_name, renderer_pid: renderer_pid}
    end

    test "duplicate ToolCallStart on same index keeps only one spinner", context do
      renderer = context.renderer_name

      # First ToolCallStart should create a spinner
      Renderer.push(renderer, %Event.ToolCallStart{index: 1, name: "read_file"})
      assert Renderer.spinner_active?(renderer, 1)

      # Second ToolCallStart for the same index must NOT overwrite
      # the spinner ref — it should be idempotent.
      Renderer.push(renderer, %Event.ToolCallStart{index: 1, name: "read_file"})

      # Then end the tool call
      Renderer.push(renderer, %Event.ToolCallEnd{
        index: 1,
        name: "read_file",
        id: "tc-1",
        arguments: "{}"
      })

      Process.sleep(20)

      # After one end event, the spinner must be cleaned up.
      # Before the fix, the duplicate start overwrote the ref,
      # so ToolCallEnd only stopped the second spinner, leaving
      # the first orphaned.
      refute Renderer.spinner_active?(renderer, 1)
      assert Renderer.spinners_idle?(renderer)
    end

    test "after duplicate start + single end, spinners_idle? is true", context do
      renderer = context.renderer_name

      Renderer.push(renderer, %Event.ToolCallStart{index: 2, name: "grep"})
      Renderer.push(renderer, %Event.ToolCallStart{index: 2, name: "grep"})

      Renderer.push(renderer, %Event.ToolCallEnd{
        index: 2,
        name: "grep",
        id: "tc-2",
        arguments: "{}"
      })

      Process.sleep(20)

      # The renderer's internal spinner_ids should be empty (all stopped)
      assert Renderer.spinners_idle?(renderer)
      refute Renderer.spinner_active?(renderer, 2)
    end

    test "idempotent ToolCallStart does not start second spinner", context do
      renderer = context.renderer_name

      Renderer.push(renderer, %Event.ToolCallStart{index: 3, name: "list_files"})
      Renderer.push(renderer, %Event.ToolCallStart{index: 3, name: "list_files"})

      # Still only one active spinner for index 3
      assert Renderer.spinner_active?(renderer, 3)

      Renderer.push(renderer, %Event.ToolCallEnd{
        index: 3,
        name: "list_files",
        id: "tc-3",
        arguments: "{}"
      })

      Process.sleep(20)

      # Cleaned up properly
      refute Renderer.spinner_active?(renderer, 3)
      assert Renderer.spinners_idle?(renderer)
    end
  end

  # ── ToolCallArgsDelta ──────────────────────────────────────────────────────

  describe "ToolCallArgsDelta" do
    test "is silently ignored (no visible output)" do
      output =
        capture_renderer(fn name ->
          Renderer.push(name, %Event.TextStart{index: 0})
          Renderer.push(name, %Event.TextDelta{index: 0, text: "baseline\n"})
          # Push a ToolCallArgsDelta — should produce no additional output
          Renderer.push(name, %Event.ToolCallArgsDelta{index: 0, arguments: "{}"})
          Renderer.push(name, %Event.TextEnd{index: 0})
        end)

      # The baseline text should appear; ArgsDelta produces nothing visible
      assert output =~ "baseline"
    end
  end

  # ── UsageUpdate ────────────────────────────────────────────────────────────

  describe "UsageUpdate" do
    test "is silently ignored (no visible output before finalization)" do
      output =
        capture_renderer(fn name ->
          Renderer.push(name, %Event.TextStart{index: 0})
          Renderer.push(name, %Event.TextDelta{index: 0, text: "baseline\n"})

          Renderer.push(name, %Event.UsageUpdate{
            prompt_tokens: 10,
            completion_tokens: 5,
            total_tokens: 15
          })

          Renderer.push(name, %Event.TextEnd{index: 0})
        end)

      # The baseline text should appear; UsageUpdate produces nothing visible
      assert output =~ "baseline"
    end
  end
end
