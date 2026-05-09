defmodule CodePuppyControl.SessionStorage.Store do
  @moduledoc """
  ETS-backed session cache with PubSub events and disk crash-survivability.

  Write path (crash-safe): SQLite → ETS → PubSub.
  Read path: ETS (O(1)) → SQLite (cache miss).
  ETS tables: `:session_store_ets` (sessions), `:session_terminal_ets` (terminals).
  (code_puppy-ctj.1)
  """

  use GenServer

  require Logger

  alias CodePuppyControl.SessionStorage.StoreHelpers
  alias CodePuppyControl.SessionStorage.Store.Operations
  alias CodePuppyControl.SessionStorage.TerminalRecovery

  @pubsub CodePuppyControl.PubSub
  @sessions_topic "sessions:events"
  @terminal_topic "terminal:recovery"

  @session_table :session_store_ets
  @terminal_table :session_terminal_ets

  # Runtime `Mix.env/0` calls are forbidden in startup paths because Mix may
  # not be available in packaged releases. Capture it at compile time instead.
  @env Mix.env()

  # (code-puppy-dt3) SQLite "database busy" retries: transient write-lock
  # contention under concurrent test load. In test env, retry 3× with
  # backoff (50ms / 100ms / 200ms) before returning {:error, :database_busy}.
  # In non-test env, don't retry — production busy_timeout (5s) should
  # suffice, and silent retries could mask real contention.
  @db_busy_max_retries if(@env == :test, do: 3, else: 0)

  # ---------------------------------------------------------------------------
  # Types
  # ---------------------------------------------------------------------------

  @type session_name :: String.t()
  @type history :: [map()]
  @type compacted_hashes :: [String.t()]

  @type session_entry :: %{
          name: session_name(),
          history: history(),
          compacted_hashes: compacted_hashes(),
          total_tokens: non_neg_integer(),
          message_count: non_neg_integer(),
          auto_saved: boolean(),
          timestamp: String.t(),
          has_terminal: boolean(),
          terminal_meta: terminal_meta() | nil,
          updated_at: integer()
        }

  @type terminal_meta :: %{
          session_id: String.t(),
          cols: pos_integer(),
          rows: pos_integer(),
          shell: String.t() | nil,
          attached_at: integer()
        }

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc "Starts the Store GenServer. Option: `:name` (default: `__MODULE__`)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Saves a session with write-through (SQLite → ETS → PubSub).
  Options: `:compacted_hashes`, `:total_tokens`, `:auto_saved`, `:timestamp`,
  `:has_terminal`, `:terminal_meta`."
  @spec save_session(session_name(), history(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def save_session(name, history, opts \\ []) do
    GenServer.call(__MODULE__, {:save_session, name, history, opts})
  end

  @doc "Loads a session (cache-first: ETS → SQLite fallback).
  Returns `{:ok, %{history:, compacted_hashes:}}` or `{:error, reason}`."
  @spec load_session(session_name()) ::
          {:ok, %{history: history(), compacted_hashes: compacted_hashes()}}
          | {:error, term()}
  def load_session(name) do
    case :ets.lookup(@session_table, name) do
      [{^name, entry}] ->
        {:ok, %{history: entry.history, compacted_hashes: entry.compacted_hashes}}

      [] ->
        case CodePuppyControl.Sessions.load_session(name) do
          {:ok, data} ->
            entry = StoreHelpers.session_data_to_entry(name, data)
            :ets.insert(@session_table, {name, entry})
            {:ok, data}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc "Loads a session with full metadata (cache-first)."
  @spec load_session_full(session_name()) ::
          {:ok, session_entry()} | {:error, term()}
  def load_session_full(name) do
    case :ets.lookup(@session_table, name) do
      [{^name, entry}] ->
        {:ok, entry}

      [] ->
        case CodePuppyControl.Sessions.load_session_full(name) do
          {:ok, session} ->
            entry = StoreHelpers.chat_session_to_entry(session)
            :ets.insert(@session_table, {name, entry})
            {:ok, entry}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc "Deletes a session with write-through (SQLite → ETS → PubSub)."
  @spec delete_session(session_name()) :: :ok | {:error, term()}
  def delete_session(name) do
    GenServer.call(__MODULE__, {:delete_session, name})
  end

  @doc "Lists all session names from ETS."
  @spec list_sessions() :: {:ok, [session_name()]}
  def list_sessions do
    names =
      @session_table
      |> :ets.match({:"$1", :_})
      |> List.flatten()
      |> Enum.sort()

    {:ok, names}
  end

  @doc "Lists sessions with metadata from ETS."
  @spec list_sessions_with_metadata() :: {:ok, [session_entry()]}
  def list_sessions_with_metadata do
    entries =
      @session_table
      |> :ets.tab2list()
      |> Enum.map(fn {_name, entry} -> entry end)
      |> Enum.sort_by(& &1.timestamp, :desc)

    {:ok, entries}
  end

  @doc "Cleans up old sessions, keeping only the most recent N."
  @spec cleanup_sessions(non_neg_integer()) :: {:ok, [session_name()]}
  def cleanup_sessions(max_sessions) do
    GenServer.call(__MODULE__, {:cleanup_sessions, max_sessions})
  end

  @doc "Checks if a session exists in ETS (O(1), no disk access)."
  @spec session_exists?(session_name()) :: boolean()
  def session_exists?(name) do
    :ets.member(@session_table, name)
  end

  @doc "Returns the count of sessions from ETS."
  @spec count_sessions() :: non_neg_integer()
  def count_sessions do
    :ets.info(@session_table, :size)
  end

  # ---------------------------------------------------------------------------
  # Terminal Session Tracking
  # ---------------------------------------------------------------------------

  @doc "Registers a terminal session for crash recovery. Durably persists to SQLite.
  If no session exists, creates a minimal row. (code_puppy-ctj.1)"
  @spec register_terminal(session_name(), terminal_meta()) ::
          :ok | {:error, term()}
  def register_terminal(session_name, meta) do
    GenServer.call(__MODULE__, {:register_terminal, session_name, meta})
  end

  @doc "Unregisters a terminal session. Durably clears terminal metadata from SQLite."
  @spec unregister_terminal(session_name()) ::
          :ok | {:error, :session_not_found | term()}
  def unregister_terminal(session_name) do
    GenServer.call(__MODULE__, {:unregister_terminal, session_name})
  end

  @doc false
  # Updates terminal metadata in ETS only, bypassing GenServer.call.
  #
  # Used exclusively during deferred terminal recovery to avoid a self-call
  # deadlock: `TerminalRecovery` runs inside the Store's
  # `handle_continue(:recover_terminals)`, so calling back into the same
  # GenServer via `register_terminal/2` would crash with "process attempted to
  # call itself".
  #
  # This function updates both ETS tables (`session_store_ets` and
  # `session_terminal_ets`) directly, and broadcasts the terminal registration
  # event via PubSub. It does NOT persist to SQLite because the terminal
  # metadata was already loaded from SQLite during `do_recover_from_disk/0`.
  @spec register_terminal_ets_only(session_name(), map()) :: :ok | :error
  def register_terminal_ets_only(name, meta) do
    case :ets.lookup(@session_table, name) do
      [{^name, entry}] ->
        updated = %{
          entry
          | has_terminal: true,
            terminal_meta: meta,
            updated_at: System.monotonic_time(:millisecond)
        }

        :ets.insert(@session_table, {name, updated})
        :ets.insert(@terminal_table, {name, meta})

        # (code_puppy-i1n) Guard against PubSub being unavailable during
        # test restart/shutdown races. Outside tests, log so dropped recovery
        # events remain visible.
        try do
          Phoenix.PubSub.broadcast(
            @pubsub,
            @terminal_topic,
            {:terminal_registered, name}
          )
        rescue
          e in ArgumentError ->
            unless @env == :test do
              Logger.warning("Terminal recovery PubSub broadcast failed: #{Exception.message(e)}")
            end

            :ok
        end

        :ok

      [] ->
        :error
    end
  end

  @doc "Lists all tracked terminal sessions (for crash recovery diagnostics)."
  @spec list_terminal_sessions() :: [terminal_meta()]
  def list_terminal_sessions do
    @terminal_table
    |> :ets.tab2list()
    |> Enum.map(fn {_name, meta} -> meta end)
  end

  @doc "Returns the PubSub topic for session events."
  @spec sessions_topic() :: String.t()
  def sessions_topic, do: @sessions_topic

  @doc "Returns the PubSub topic for terminal recovery events."
  @spec terminal_topic() :: String.t()
  def terminal_topic, do: @terminal_topic

  @doc "Subscribes to session lifecycle events via PubSub.
  Events: `{:session_saved, name, meta}`, `{:session_deleted, name}`, `{:sessions_cleaned, names}`."
  @spec subscribe_sessions() :: :ok | {:error, term()}
  def subscribe_sessions do
    Phoenix.PubSub.subscribe(@pubsub, @sessions_topic)
  end

  @doc "Subscribes to terminal recovery events via PubSub.
  Events: `{:terminal_registered, id}`, `{:terminal_unregistered, id}`, etc."
  @spec subscribe_terminal() :: :ok | {:error, term()}
  def subscribe_terminal do
    Phoenix.PubSub.subscribe(@pubsub, @terminal_topic)
  end

  # ---------------------------------------------------------------------------
  # Update & Search (code_puppy-ctj.1 fresh port)
  # ---------------------------------------------------------------------------

  @doc "Updates session metadata without rewriting history.
  Options: `:auto_saved`, `:total_tokens`, `:timestamp`.
  Returns `{:error, :not_found}` if session does not exist. (code_puppy-ctj.1)"
  @spec update_session(session_name(), keyword()) ::
          {:ok, map()} | {:error, :not_found | term()}
  def update_session(name, opts) do
    GenServer.call(__MODULE__, {:update_session, name, opts})
  end

  @doc "Searches sessions by filters against ETS (no disk I/O).
  Options: `:name_pattern` (string/regex), `:auto_saved`, `:min_tokens`,
  `:max_tokens`, `:since`, `:until` (ISO8601), `:limit` (default 100).
  Returns `{:ok, [metadata_map]}`. (code_puppy-ctj.1)"
  @spec search_sessions(keyword()) :: {:ok, [map()]}
  def search_sessions(opts \\ []) do
    entries =
      @session_table
      |> :ets.tab2list()
      |> Enum.map(fn {_, e} -> e end)

    filtered =
      entries
      |> StoreHelpers.filter_by_name(Keyword.get(opts, :name_pattern))
      |> StoreHelpers.filter_by_auto_saved(Keyword.get(opts, :auto_saved))
      |> StoreHelpers.filter_by_token_range(
        Keyword.get(opts, :min_tokens),
        Keyword.get(opts, :max_tokens)
      )
      |> StoreHelpers.filter_by_time_range(
        Keyword.get(opts, :since),
        Keyword.get(opts, :until)
      )
      |> Enum.sort_by(& &1.timestamp, :desc)
      |> Enum.take(Keyword.get(opts, :limit, 100))

    {:ok, Enum.map(filtered, &store_entry_to_metadata/1)}
  end

  # ---------------------------------------------------------------------------
  # Server Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    session_table =
      :ets.new(@session_table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    terminal_table =
      :ets.new(@terminal_table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    # (code_puppy-i1n) In test env, the Ecto sandbox pool may not be
    # checked out yet, so Repo calls during init can raise
    # DBConnection.OwnershipError. A fresh/empty test DB can also raise a
    # narrow "no such table" Exqlite.Error during startup recovery. Catch
    # those gracefully only in tests; in other environments, reraise so real
    # persistence failures are visible.
    # (code-puppy-be7) In escript mode, Repo is not started at all, so
    # disk recovery raises RuntimeError ("could not lookup Ecto repo").
    # Catch that too — the Store starts with 0 sessions.
    recovered =
      try do
        Operations.do_recover_from_disk()
      rescue
        e in [DBConnection.OwnershipError, Exqlite.Error] ->
          handle_init_repo_error(e, __STACKTRACE__)

        e in RuntimeError ->
          if String.contains?(Exception.message(e), "could not lookup Ecto repo") do
            # (code_puppy-be7) Expected in escript mode — debug, not warning.
            Logger.debug(
              "SessionStorage.Store: Repo not started (escript mode?); skipping disk recovery"
            )

            0
          else
            reraise e, __STACKTRACE__
          end
      end

    terminal_count =
      @session_table
      |> :ets.tab2list()
      |> Enum.count(fn {_name, entry} -> entry.has_terminal end)

    Logger.info(
      "SessionStorage.Store initialized: #{recovered} sessions recovered, " <>
        "#{terminal_count} terminal sessions pending recovery (deferred)"
    )

    {:ok,
     %{
       session_table: session_table,
       terminal_table: terminal_table,
       opts: opts,
       pending_terminal_recovery: terminal_count > 0
     }, {:continue, :recover_terminals}}
  end

  # (code_puppy-i1n) All handle_call callbacks that delegate to
  # Operations (which uses the Repo) must rescue DBConnection.OwnershipError.
  # In test env with the Ecto Sandbox pool, the Store GenServer is a
  # long-lived process that doesn't own a sandbox connection — so any
  # Repo call can fail if a test process has checked out the pool.
  # Returning {:error, :repo_unavailable} keeps the Store alive and
  # prevents a restart storm that would crash the application supervisor.

  @impl true
  def handle_call({:save_session, name, history, opts}, _from, state) do
    {:reply, safe_repo(fn -> Operations.do_save_session(name, history, opts) end), state}
  end

  @impl true
  def handle_call({:delete_session, name}, _from, state) do
    {:reply, safe_repo(fn -> Operations.do_delete_session(name) end), state}
  end

  @impl true
  def handle_call({:cleanup_sessions, max_sessions}, _from, state) do
    {:reply, safe_repo(fn -> Operations.do_cleanup_sessions(max_sessions) end), state}
  end

  @impl true
  def handle_call({:register_terminal, session_name, meta}, _from, state) do
    {:reply, safe_repo(fn -> Operations.do_register_terminal(session_name, meta) end), state}
  end

  @impl true
  def handle_call({:unregister_terminal, session_name}, _from, state) do
    {:reply, safe_repo(fn -> Operations.do_unregister_terminal(session_name) end), state}
  end

  @impl true
  def handle_call({:update_session, name, opts}, _from, state) do
    {:reply, safe_repo(fn -> Operations.do_update_session(name, opts) end), state}
  end

  # Wraps a Repo-dependent call so test-only DBConnection.OwnershipError
  # doesn't crash the Store GenServer. Returns {:error, :repo_unavailable} on
  # sandbox contention, letting the Store stay alive for ETS-only reads. In
  # non-test environments, and for unexpected DB errors in tests, reraise so
  # real persistence failures stay visible. (code_puppy-i1n)
  # (code-puppy-be7) Also catches RuntimeError when Repo is not started
  # (escript mode).
  # (code-puppy-dt3) Also catches Exqlite.Error for "database busy" with
  # retry + backoff in test env.
  defp safe_repo(fun) do
    safe_repo(fun, @db_busy_max_retries)
  end

  defp safe_repo(fun, retries_left) do
    fun.()
  rescue
    e in [DBConnection.OwnershipError] ->
      handle_repo_error(e, __STACKTRACE__)

    e in Exqlite.Error ->
      if database_busy?(e) and retries_left > 0 do
        backoff = db_busy_backoff(retries_left)

        Logger.debug("Store: SQLite busy, retrying (#{retries_left} left, #{backoff}ms backoff)")

        Process.sleep(backoff)
        safe_repo(fun, retries_left - 1)
      else
        handle_exqlite_busy_error(e, __STACKTRACE__)
      end

    e in RuntimeError ->
      if String.contains?(Exception.message(e), "could not lookup Ecto repo") do
        {:error, :repo_unavailable}
      else
        reraise e, __STACKTRACE__
      end
  end

  # (code-puppy-dt3) Detects SQLite write-lock contention errors that
  # are transient and retryable. Matches the canonical SQLite error
  # messages "database is busy" and "database is locked".
  defp database_busy?(%Exqlite.Error{message: msg}) when is_binary(msg) do
    lower = String.downcase(msg)

    String.contains?(lower, "database is busy") or
      String.contains?(lower, "database is locked")
  end

  defp database_busy?(_), do: false

  # (code-puppy-dt3) Exponential-ish backoff for SQLite busy retries.
  # 3 retries left → 50ms, 2 → 100ms, 1 → 200ms.
  defp db_busy_backoff(retries_left) when retries_left >= 3, do: 50
  defp db_busy_backoff(retries_left) when retries_left >= 2, do: 100
  defp db_busy_backoff(_), do: 200

  # (code-puppy-dt3) Handles Exqlite.Error after retries are exhausted
  # (or in non-test env where retries are disabled).
  defp handle_exqlite_busy_error(e, stacktrace) do
    if @env == :test do
      Logger.warning(
        "Store: SQLite error after retries (#{Exception.message(e)}); returning :database_busy"
      )

      {:error, :database_busy}
    else
      reraise e, stacktrace
    end
  end

  defp handle_init_repo_error(%DBConnection.OwnershipError{} = e, stacktrace) do
    if @env == :test do
      Logger.warning(
        "SessionStorage.Store: Repo unavailable during init (#{Exception.message(e)}); skipping disk recovery"
      )

      0
    else
      reraise e, stacktrace
    end
  end

  defp handle_init_repo_error(%Exqlite.Error{} = e, stacktrace) do
    cond do
      @env == :test and missing_table_error?(e) ->
        Logger.warning(
          "SessionStorage.Store: test DB schema unavailable during init (#{Exception.message(e)}); skipping disk recovery"
        )

        0

      @env == :test and database_busy?(e) ->
        # (code-puppy-dt3) Transient contention during init recovery —
        # start with 0 sessions; they'll be recovered on next restart.
        Logger.warning(
          "SessionStorage.Store: SQLite busy during init (#{Exception.message(e)}); skipping disk recovery"
        )

        0

      true ->
        reraise e, stacktrace
    end
  end

  defp missing_table_error?(%Exqlite.Error{message: message}) when is_binary(message) do
    String.contains?(message, "no such table")
  end

  defp missing_table_error?(_error), do: false

  defp handle_repo_error(e, stacktrace) do
    if @env == :test do
      Logger.warning(
        "Store: Repo unavailable (#{Exception.message(e)}); returning :repo_unavailable"
      )

      {:error, :repo_unavailable}
    else
      reraise e, stacktrace
    end
  end

  # ---------------------------------------------------------------------------
  # Deferred Terminal Recovery (code_puppy-ctj.1 fix)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_continue(:recover_terminals, %{pending_terminal_recovery: false} = state),
    do: {:noreply, state}

  def handle_continue(:recover_terminals, state) do
    # (code_puppy-i1n) TerminalRecovery may also hit the Repo (e.g.
    # PtyManager.create_session), so wrap it in safe_repo too.
    safe_repo(fn ->
      TerminalRecovery.deferred_recover_from_store()
      :ok
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:retry_terminal_recovery, attempt}, state) do
    safe_repo(fn ->
      TerminalRecovery.attempt_recovery_from_store(attempt)
      :ok
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp store_entry_to_metadata(entry) do
    %{
      session_name: entry.name,
      timestamp: entry.timestamp,
      message_count: entry.message_count,
      total_tokens: entry.total_tokens,
      auto_saved: entry.auto_saved
    }
  end

  # ---------------------------------------------------------------------------
  # Child Spec
  # ---------------------------------------------------------------------------

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end
end
