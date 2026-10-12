defmodule Fides.Banking.Adapters.EsJson do
  @moduledoc """
  Spain's provider: JSON with amounts in cents.

      {"cliente": {"iban": "ES91...", "deuda_total_centimos": 1200000,
                   "ingresos": {"mensual_centimos": 250000, "meses_con_ingresos": 6}},
       "puntuacion": 720}
  """

  @behaviour Fides.Banking.Adapters.Adapter

  import Fides.Banking.Adapters.Values

  alias Fides.Banking.Adapters.Profile

  @impl true
  def key, do: "es_json"

  @impl true
  def parse(body) do
    case Jason.decode(body) do
      {:ok, answer} ->
        Profile.build(
          observed_income_minor: dig(answer, ["cliente", "ingresos", "mensual_centimos"]),
          total_debt_minor: dig(answer, ["cliente", "deuda_total_centimos"]),
          income_months: dig(answer, ["cliente", "ingresos", "meses_con_ingresos"]),
          score: dig(answer, ["puntuacion"]),
          account_masked: mask(dig(answer, ["cliente", "iban"]))
        )

      {:error, _reason} ->
        {:error, {:malformed, :body}}
    end
  end
end
