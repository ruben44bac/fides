defmodule Fides.Banking.Adapters.CoJson do
  @moduledoc """
  Colombia's provider: JSON with amounts in whole pesos, including the total debt
  the country's rule compares with income.

      {"ingreso_mensual_pesos": 4500000, "deuda_total_pesos": 15000000,
       "meses_con_ingreso": 6, "puntaje": 650, "cuenta": "123-456789-01"}
  """

  @behaviour Fides.Banking.Adapters.Adapter

  import Fides.Banking.Adapters.Values

  alias Fides.Banking.Adapters.Profile

  @impl true
  def key, do: "co_json"

  @impl true
  def parse(body) do
    case Jason.decode(body) do
      {:ok, answer} ->
        Profile.build(
          observed_income_minor: whole_units(dig(answer, ["ingreso_mensual_pesos"])),
          total_debt_minor: whole_units(dig(answer, ["deuda_total_pesos"])),
          income_months: dig(answer, ["meses_con_ingreso"]),
          score: dig(answer, ["puntaje"]),
          account_masked: mask(dig(answer, ["cuenta"]))
        )

      {:error, _reason} ->
        {:error, {:malformed, :body}}
    end
  end
end
