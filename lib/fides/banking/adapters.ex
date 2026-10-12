defmodule Fides.Banking.Adapters do
  @moduledoc """
  The anti-corruption layer between Fides and each country's bank provider.

  Every provider answers in its own format: amounts in cents or in whole pesos,
  decimal commas, XML, scores on its own fields. Each adapter translates its
  provider's answer into the same `Fides.Banking.Adapters.Profile`, so nothing else
  in Fides ever sees a provider's format. Pure functions, so every format can be
  tested against recorded answers.

  Answers larger than 64 KB are rejected before parsing.
  """

  use Boundary, type: :strict, deps: [Jason, Decimal], exports: [Profile]

  alias Fides.Banking.Adapters.BrJson
  alias Fides.Banking.Adapters.CoJson
  alias Fides.Banking.Adapters.EsJson
  alias Fides.Banking.Adapters.ItXml
  alias Fides.Banking.Adapters.MxWebhook
  alias Fides.Banking.Adapters.Profile
  alias Fides.Banking.Adapters.PtJson

  @adapters [EsJson, PtJson, ItXml, MxWebhook, CoJson, BrJson]
  @max_body_bytes 64 * 1024

  @doc "Keys of the available adapters, as stored on each bank provider."
  @spec keys() :: [String.t()]
  def keys, do: Enum.map(@adapters, & &1.key())

  @doc "Translates a provider's answer into a profile."
  @spec parse(String.t(), binary()) ::
          {:ok, Profile.t()} | {:error, :unknown_adapter | {:malformed, atom()}}
  def parse(key, body) when is_binary(body) do
    case Enum.find(@adapters, &(&1.key() == key)) do
      nil -> {:error, :unknown_adapter}
      _adapter when byte_size(body) > @max_body_bytes -> {:error, {:malformed, :body}}
      adapter -> adapter.parse(body)
    end
  end
end
