defmodule Fides.Banking.Adapters.Adapter do
  @moduledoc "What each provider's adapter implements."

  alias Fides.Banking.Adapters.Profile

  @doc "The adapter key, as stored on the bank provider."
  @callback key() :: String.t()

  @doc "Translates the provider's answer, or names the first field that is malformed."
  @callback parse(binary()) :: {:ok, Profile.t()} | {:error, {:malformed, atom()}}

  @doc "The identity of an answer that arrives later: its event id, its sequence and the request it answers."
  @callback envelope(binary()) ::
              {:ok, %{event_id: String.t(), sequence: non_neg_integer(), request_id: String.t()}}
              | {:error, {:malformed, :body}}

  @optional_callbacks envelope: 1
end
