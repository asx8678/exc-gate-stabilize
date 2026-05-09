defmodule CodePuppyControl.Agent.Loop.Streaming do
  @moduledoc """
  Streaming and response accumulation logic for Agent.Loop.

  Handles building the stream callback and accumulating streamed
  responses into a `Turn` struct.

  Tool-call-lifecycle events are owned by `ToolDispatch`; this module
  only emits `llm_stream` text-chunk events from the provider stream.

  Extracted from `Agent.Loop` to keep it under the 600-line hard cap.
  """

  alias CodePuppyControl.Agent.{Events, Turn}
  alias CodePuppyControl.Stream.Event

  @doc """
  Build the callback function that receives streaming events from the LLM.

  The callback publishes `llm_stream` events via the EventBus as they arrive.

  Tool-call-lifecycle events (`tool_call_start` / `tool_call_end`) are
  emitted exclusively by `ToolDispatch` when actual tool execution begins
  and ends.  Provider stream events (`%Event.ToolCallEnd{}`) signal only
  that the model finished emitting a tool-call block — they must **not**
  emit execution-lifecycle events, which would duplicate the ones from
  `ToolDispatch` and cause orphaned spinners in the TUI.
  """
  @spec build_stream_callback(map()) :: (term() -> term())
  def build_stream_callback(state) do
    fn
      {:stream, %Event.TextDelta{text: text}} when is_binary(text) ->
        Events.publish(Events.llm_stream(state.run_id, state.session_id, text))

      {:stream, %Event.ToolCallEnd{}} ->
        # Provider finished emitting a tool-call block.
        # Execution-lifecycle events are owned by ToolDispatch.
        :ok

      {:stream, %Event.Done{}} ->
        :ok

      {:stream, _other} ->
        :ok

      _other ->
        :ok
    end
  end

  @doc """
  Accumulate a streamed LLM response into the turn.

  Appends text and tool calls from the response to the turn's
  accumulated state.
  """
  @spec accumulate_response(Turn.t(), map()) :: Turn.t()
  def accumulate_response(turn, %{text: text, tool_calls: tool_calls} = response) do
    turn =
      if text && text != "" do
        case Turn.append_text(turn, text) do
          {:ok, t} -> t
          _ -> turn
        end
      else
        turn
      end

    turn =
      Enum.reduce(tool_calls || [], turn, fn tc, acc ->
        case Turn.add_tool_call(acc, tc) do
          {:ok, t} -> t
          _ -> acc
        end
      end)

    # Store usage data from provider response
    case response[:usage] || response["usage"] do
      nil -> turn
      usage -> %{turn | usage: usage}
    end
  end

  def accumulate_response(turn, _other), do: turn
end
