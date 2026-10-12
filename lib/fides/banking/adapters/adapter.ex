defmodule Fides.Banking.Adapters.Adapter do
  @moduledoc "What each provider's adapter implements."

  alias Fides.Banking.Adapters.Profile

  @doc "The adapter key, as stored on the bank provider."
  @callback key() :: String.t()

  @doc "Translates the provider's answer, or names the first field that is malformed."
  @callback parse(binary()) :: {:ok, Profile.t()} | {:error, {:malformed, atom()}}
end
