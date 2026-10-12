defmodule Fides.Banking.Adapters.BrJson do
  @moduledoc """
  Brazil's provider: JSON in camelCase with amounts in centavos and a credit score
  from 0 to 1000, which the country's rule decides on.

      {"rendaMensalCentavos": 850000, "dividaTotalCentavos": 2500000,
       "mesesComRenda": 6, "score": 742,
       "conta": {"agencia": "0001", "numero": "123456-7"}}
  """

  @behaviour Fides.Banking.Adapters.Adapter

  import Fides.Banking.Adapters.Values

  alias Fides.Banking.Adapters.Profile

  @impl true
  def key, do: "br_json"

  @impl true
  def parse(body) do
    case Jason.decode(body) do
      {:ok, answer} ->
        Profile.build(
          observed_income_minor: dig(answer, ["rendaMensalCentavos"]),
          total_debt_minor: dig(answer, ["dividaTotalCentavos"]),
          income_months: dig(answer, ["mesesComRenda"]),
          score: dig(answer, ["score"]),
          account_masked: mask(dig(answer, ["conta", "numero"]))
        )

      {:error, _reason} ->
        {:error, {:malformed, :body}}
    end
  end
end
