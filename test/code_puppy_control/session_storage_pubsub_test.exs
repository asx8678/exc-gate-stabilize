defmodule CodePuppyControl.SessionStoragePubSubTest do
  @moduledoc """
  Tests for SessionStorage PubSub integration.

  These tests verify per-session and global PubSub subscriptions,
  broadcast event shapes, and Store integration.

  Ported from abandoned branch `feature/d-ctj-1-session-storage` and
  rewritten for the fresh port architecture (no ETSCache, Store is
  the single source of truth for PubSub events).

  (code_puppy-ctj.1 fresh port)
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Repo
  alias CodePuppyControl.SessionStorage

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    # These tests interact with the Store GenServer, which uses Ecto/Repo for
    # durable persistence.  Check out a sandbox connection in {:shared, self()}
    # mode so the Store's process (a separate GenServer) can also use the Repo.
    # Without this, the Store's Ecto calls fail with DBConnection.OwnershipError
    # because the pool is configured as Ecto.Adapters.SQL.Sandbox in :manual
    # mode.  (code_puppy-i1n)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    prefix = "pubsub_#{System.unique_integer([:positive])}"

    tmp =
      Path.join(System.tmp_dir!(), "session_pubsub_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)

      # (code-puppy-mkk.4) Clean up ETS entries by prefix — the sandbox
      # rolls back SQLite, but ETS persists across tests since the Store
      # GenServer is long-lived and doesn't re-init between test cases.
      # Same closure-capture bug as code-puppy-dt3: prefix-based deletion
      # correctly removes all sessions created by this test.
      for {name, _} <- :ets.tab2list(:session_store_ets) do
        if String.starts_with?(to_string(name), prefix) do
          try do
            :ets.delete(:session_store_ets, name)
            :ets.delete(:session_terminal_ets, name)
          catch
            :error, :badarg -> :ok
          end
        end
      end

      # Unsubscribe from any PubSub topics to avoid cross-test pollution
      try do
        SessionStorage.unsubscribe_all()
      catch
        _ -> :ok
      end
    end)

    {:ok, prefix: prefix, base_dir: tmp}
  end

  # Helper: generate a unique session name for this test run
  defp session_name(prefix, label) do
    "#{prefix}-#{label}"
  end

  # ---------------------------------------------------------------------------
  # Per-session Subscribe / Unsubscribe
  # ---------------------------------------------------------------------------

  describe "subscribe/1 and unsubscribe/1" do
    test "subscribes to a session-specific topic and receives events", ctx do
      name = session_name(ctx.prefix, "subscribe")

      assert :ok = SessionStorage.subscribe(name)

      # Save session — should broadcast per-session event
      {:ok, _} =
        SessionStorage.save_session(name, [%{"role" => "user", "content" => "hi"}])

      assert_receive {:session_event, %{type: :saved, name: ^name}}, 500

      :ok = SessionStorage.unsubscribe(name)
    end

    test "unsubscribe removes subscription", ctx do
      name = session_name(ctx.prefix, "unsubscribe")

      :ok = SessionStorage.subscribe(name)
      :ok = SessionStorage.unsubscribe(name)

      # After unsubscribe, should not receive events
      {:ok, _} =
        SessionStorage.save_session(name, [%{"role" => "user", "content" => "hi"}])

      refute_receive {:session_event, _}, 100
    end
  end

  # ---------------------------------------------------------------------------
  # Global Subscribe / Unsubscribe
  # ---------------------------------------------------------------------------

  describe "subscribe_all/0 and unsubscribe_all/0" do
    test "subscribes to global session events and receives legacy-shape events", ctx do
      name = session_name(ctx.prefix, "global-test")

      assert :ok = SessionStorage.subscribe_all()

      {:ok, _} =
        SessionStorage.save_session(name, [%{"role" => "user", "content" => "hi"}])

      # Global topic uses legacy tuple shape
      assert_receive {:session_saved, ^name, _meta}, 500

      :ok = SessionStorage.unsubscribe_all()
    end

    test "unsubscribe_all stops receiving global events", ctx do
      name = session_name(ctx.prefix, "global-unsub-test")

      :ok = SessionStorage.subscribe_all()
      :ok = SessionStorage.unsubscribe_all()

      {:ok, _} =
        SessionStorage.save_session(name, [%{"role" => "user", "content" => "hi"}])

      refute_receive {:session_saved, _, _}, 100
    end
  end

  # ---------------------------------------------------------------------------
  # Broadcast Event Shapes
  # ---------------------------------------------------------------------------

  describe "event shapes from Store operations" do
    test "save_session broadcasts per-session :saved event with payload", ctx do
      name = session_name(ctx.prefix, "shape-save-test")

      :ok = SessionStorage.subscribe(name)

      {:ok, _} =
        SessionStorage.save_session(name, [%{"role" => "user", "content" => "test"}],
          total_tokens: 42
        )

      assert_receive {:session_event, event}, 500

      assert event.type == :saved
      assert event.name == name
      assert event.timestamp != nil
      assert event.payload.total_tokens == 42
    end

    test "delete_session broadcasts per-session :deleted event", ctx do
      name = session_name(ctx.prefix, "shape-delete-test")

      {:ok, _} =
        SessionStorage.save_session(name, [%{"role" => "user", "content" => "test"}])

      :ok = SessionStorage.subscribe(name)
      :ok = SessionStorage.delete_session(name)

      assert_receive {:session_event, %{type: :deleted, name: ^name}}, 500
    end

    test "update_session broadcasts per-session :updated event", ctx do
      name = session_name(ctx.prefix, "shape-update-test")

      {:ok, _} =
        SessionStorage.save_session(name, [%{"role" => "user", "content" => "test"}])

      :ok = SessionStorage.subscribe(name)

      {:ok, _} =
        SessionStorage.update_session(name, total_tokens: 999)

      assert_receive {:session_event, %{type: :updated, name: ^name}}, 500
    end

    test "cleanup_sessions broadcasts per-session :deleted events", ctx do
      # Create 3 sessions
      for i <- 1..3 do
        {:ok, _} =
          SessionStorage.save_session(session_name(ctx.prefix, "cleanup-test-#{i}"), [
            %{"role" => "user", "content" => "#{i}"}
          ])
      end

      # Subscribe to one of the sessions that will be cleaned up
      cleanup_name = session_name(ctx.prefix, "cleanup-test-1")
      :ok = SessionStorage.subscribe(cleanup_name)

      # Keep only 1 session (deletes the oldest 2)
      {:ok, _deleted} = SessionStorage.cleanup_sessions(1)

      # The per-session event should fire for each deleted session
      assert_receive {:session_event, %{type: :deleted, name: ^cleanup_name}}, 500
    end
  end

  # ---------------------------------------------------------------------------
  # Global Event Shapes (legacy)
  # ---------------------------------------------------------------------------

  describe "global event shapes (legacy tuples)" do
    test "save_session broadcasts {:session_saved, name, meta} on global topic", ctx do
      name = session_name(ctx.prefix, "global-save-test")

      :ok = SessionStorage.subscribe_all()

      {:ok, _} =
        SessionStorage.save_session(name, [%{"role" => "user", "content" => "test"}])

      assert_receive {:session_saved, ^name, _meta}, 500
    end

    test "delete_session broadcasts {:session_deleted, name} on global topic", ctx do
      name = session_name(ctx.prefix, "global-delete-test")

      {:ok, _} =
        SessionStorage.save_session(name, [%{"role" => "user", "content" => "test"}])

      :ok = SessionStorage.subscribe_all()
      :ok = SessionStorage.delete_session(name)

      assert_receive {:session_deleted, ^name}, 500
    end
  end

  # ---------------------------------------------------------------------------
  # Event Type Enumeration
  # ---------------------------------------------------------------------------

  describe "all expected event types fire" do
    test ":saved, :updated, :deleted on per-session topic", ctx do
      name = session_name(ctx.prefix, "event-types-test")

      :ok = SessionStorage.subscribe(name)

      # :saved
      {:ok, _} =
        SessionStorage.save_session(name, [%{"role" => "user", "content" => "test"}])

      assert_receive {:session_event, %{type: :saved}}, 500

      # :updated
      {:ok, _} =
        SessionStorage.update_session(name, total_tokens: 42)

      assert_receive {:session_event, %{type: :updated}}, 500

      # :deleted
      :ok = SessionStorage.delete_session(name)
      assert_receive {:session_event, %{type: :deleted}}, 500
    end
  end

  # ---------------------------------------------------------------------------
  # Async Operations + PubSub
  # ---------------------------------------------------------------------------

  describe "save_session_async/3 with PubSub" do
    test "async save triggers per-session broadcast", ctx do
      name = session_name(ctx.prefix, "async-pubsub-test")

      :ok = SessionStorage.subscribe(name)

      :ok =
        SessionStorage.save_session_async(name, [
          %{"role" => "user", "content" => "async"}
        ])

      # Wait for the background Task to complete and event to fire
      assert_receive {:session_event, %{type: :saved, name: ^name}}, 1000
    end

    test "async save triggers global broadcast", ctx do
      name = session_name(ctx.prefix, "async-global-test")

      :ok = SessionStorage.subscribe_all()

      :ok =
        SessionStorage.save_session_async(name, [
          %{"role" => "user", "content" => "async"}
        ])

      assert_receive {:session_saved, ^name, _meta}, 1000
    end
  end

  # ---------------------------------------------------------------------------
  # Dual-subscription (per-session + global simultaneously)
  # ---------------------------------------------------------------------------

  describe "dual subscription" do
    test "process receives both per-session and global events", ctx do
      name = session_name(ctx.prefix, "dual-sub-test")

      :ok = SessionStorage.subscribe(name)
      :ok = SessionStorage.subscribe_all()

      {:ok, _} =
        SessionStorage.save_session(name, [%{"role" => "user", "content" => "dual"}])

      # Should receive both event shapes
      assert_receive {:session_event, %{type: :saved, name: ^name}}, 500
      assert_receive {:session_saved, ^name, _meta}, 500
    end
  end
end
