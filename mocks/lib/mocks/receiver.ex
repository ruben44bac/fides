defmodule Mocks.Receiver do
  @moduledoc """
  The simulated system that receives Fides' webhooks. It checks each delivery's
  signature with `MOCKS_RECEIVER_SECRET`, keeps what it received and processes each
  event id once, however many times it is delivered. With `MOCKS_RECEIVER_DOWN=1` it
  answers 503, so a demo can watch Fides retry.
  """

  use Agent

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts),
    do: Agent.start_link(fn -> %{events: [], seen: MapSet.new()} end, name: __MODULE__)

  @doc "Keeps a delivered event; `:duplicate` when its id was seen before."
  @spec record(map()) :: :new | :duplicate
  def record(%{"event_id" => id} = event) do
    Agent.get_and_update(__MODULE__, fn state ->
      if MapSet.member?(state.seen, id) do
        {:duplicate, state}
      else
        received = Map.put(event, "received_at", DateTime.utc_now() |> DateTime.to_iso8601())
        {:new, %{events: [received | state.events], seen: MapSet.put(state.seen, id)}}
      end
    end)
  end

  @doc "Everything received, newest first."
  @spec events() :: [map()]
  def events, do: Agent.get(__MODULE__, & &1.events)

  @spec clear() :: :ok
  def clear, do: Agent.update(__MODULE__, fn _state -> %{events: [], seen: MapSet.new()} end)

  @doc "Checks a delivery's signature, within five minutes of its time."
  @spec verify(String.t() | nil, String.t(), integer()) :: :ok | {:error, :invalid}
  def verify(header, body, now) do
    with %{"t" => timestamp, "v1" => digest} <-
           Regex.named_captures(~r/^t=(?<t>\d{1,12}),v1=(?<v1>[0-9a-f]{64})$/, header || ""),
         timestamp = String.to_integer(timestamp),
         true <- abs(now - timestamp) <= 300,
         expected = Mocks.Webhook.sign(Mocks.Settings.receiver_secret(), body, timestamp),
         true <- Plug.Crypto.secure_compare("t=#{timestamp},v1=#{digest}", expected) do
      :ok
    else
      _invalid -> {:error, :invalid}
    end
  end
end
