defmodule CodePuppyControl.Agent.Events do
  @moduledoc """
  Agent event type definitions.

  Defines the structured events emitted during agent runs. These events
  are published via `CodePuppyControl.EventBus` and follow the existing
  event schema (type, run_id, session_id, timestamp).

  ## Event Types

  | Event                      | When                                     |
  |----------------------------|------------------------------------------|
  | `{:turn_started, n}`       | A new turn begins                        |
  | `{:llm_stream, chunk}`     | A text chunk arrives from the LLM        |
  | `{:tool_call_start, ...}`  | A tool call is dispatched                |
  | `{:tool_call_end, ...}`    | A tool call completes                    |
  | `{:turn_ended, n, reason}` | A turn finishes (done/error/halt)        |
  | `{:run_completed, summary}`| The entire run completes successfully    |
  | `{:run_failed, error}`     | The run fails                            |

  ## Usage

      # Build an event map
      event = Events.turn_started(run_id, session_id, 1)

      # Publish via EventBus (handles PubSub + EventStore)
      EventBus.broadcast_event(event)
  """

  alias CodePuppyControl.EventBus

  # ---------------------------------------------------------------------------
  # Event Builders
  # ---------------------------------------------------------------------------

  @doc """
  Builds a `turn_started` event.
  """
  @spec turn_started(String.t(), String.t() | nil, non_neg_integer()) :: map()
  def turn_started(run_id, session_id, turn_number) do
    %{
      type: "agent_turn_started",
      run_id: run_id,
      session_id: session_id,
      turn_number: turn_number,
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Builds an `llm_stream` event for a text chunk.
  """
  @spec llm_stream(String.t(), String.t() | nil, String.t()) :: map()
  def llm_stream(run_id, session_id, chunk) when is_binary(chunk) do
    %{
      type: "agent_llm_stream",
      run_id: run_id,
      session_id: session_id,
      chunk: chunk,
      chunk_size: byte_size(chunk),
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Builds a `tool_call_start` event.
  """
  @spec tool_call_start(String.t(), String.t() | nil, atom() | String.t(), map(), String.t()) ::
          map()
  def tool_call_start(run_id, session_id, tool_name, arguments, tool_call_id) do
    %{
      type: "agent_tool_call_start",
      run_id: run_id,
      session_id: session_id,
      tool_name: to_string(tool_name),
      arguments: arguments,
      tool_call_id: tool_call_id,
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Builds a `tool_call_end` event.
  """
  @spec tool_call_end(String.t(), String.t() | nil, atom() | String.t(), term(), String.t()) ::
          map()
  def tool_call_end(run_id, session_id, tool_name, result, tool_call_id) do
    %{
      type: "agent_tool_call_end",
      run_id: run_id,
      session_id: session_id,
      tool_name: to_string(tool_name),
      result: result,
      tool_call_id: tool_call_id,
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Builds a `turn_ended` event.
  """
  @spec turn_ended(String.t(), String.t() | nil, non_neg_integer(), atom()) :: map()
  def turn_ended(run_id, session_id, turn_number, reason) do
    %{
      type: "agent_turn_ended",
      run_id: run_id,
      session_id: session_id,
      turn_number: turn_number,
      reason: to_string(reason),
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Builds a `messages_compacted` event.

  Emitted when compaction/pruning reduces the message history
  before an LLM call.
  """
  @spec messages_compacted(String.t(), String.t() | nil, map()) :: map()
  def messages_compacted(run_id, session_id, stats) when is_map(stats) do
    %{
      type: "agent_messages_compacted",
      run_id: run_id,
      session_id: session_id,
      stats: stats,
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Builds a `run_completed` event.
  """
  @spec run_completed(String.t(), String.t() | nil, map()) :: map()
  def run_completed(run_id, session_id, summary) do
    %{
      type: "agent_run_completed",
      run_id: run_id,
      session_id: session_id,
      summary: summary,
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Builds a `run_failed` event.
  """
  @spec run_failed(String.t(), String.t() | nil, term()) :: map()
  def run_failed(run_id, session_id, error) do
    %{
      type: "agent_run_failed",
      run_id: run_id,
      session_id: session_id,
      error: format_error(error),
      timestamp: DateTime.utc_now()
    }
  end

  # ---------------------------------------------------------------------------
  # Publishing Helpers
  # ---------------------------------------------------------------------------

  @doc """
  Builds and publishes an agent event via EventBus.
  """
  @spec publish(map()) :: :ok
  def publish(event) when is_map(event) do
    EventBus.broadcast_event(event)
  end

  # ---------------------------------------------------------------------------
  # Serialization
  # ---------------------------------------------------------------------------

  @doc """
  Encodes an event to JSON.

  Returns `{:ok, json_string}` or `{:error, reason}`.
  """
  @spec to_json(map()) :: {:ok, String.t()} | {:error, term()}
  def to_json(event) when is_map(event) do
    Jason.encode(event)
  end

  @doc """
  Decodes a JSON string to an event map.

  Returns `{:ok, event_map}` or `{:error, reason}`.
  """
  @spec from_json(String.t()) :: {:ok, map()} | {:error, term()}
  def from_json(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} -> {:ok, map}
      {:ok, _} -> {:error, :invalid_event_format}
      error -> error
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp format_error(%{__exception__: true} = ex) do
    Exception.message(ex)
  end

  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error)
end
