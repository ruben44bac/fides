defmodule Fides.Banking.Adapters.PtJson do
  @moduledoc """
  Portugal's provider: JSON with Portuguese field names and amounts as text with a
  decimal comma and dots between thousands.

      {"rendimento_mensal": "2.500,00", "divida_total": "12.000,50",
       "meses_com_rendimento": 6, "pontuacao": 710, "iban": "PT50..."}
  """

  @behaviour Fides.Banking.Adapters.Adapter

  import Fides.Banking.Adapters.Values

  alias Fides.Banking.Adapters.Profile

  @separators [decimal: ",", thousands: "."]

  @impl true
  def key, do: "pt_json"

  @impl true
  def parse(body) do
    case Jason.decode(body) do
      {:ok, answer} ->
        Profile.build(
          observed_income_minor: amount(dig(answer, ["rendimento_mensal"]), @separators),
          total_debt_minor: amount(dig(answer, ["divida_total"]), @separators),
          income_months: dig(answer, ["meses_com_rendimento"]),
          score: dig(answer, ["pontuacao"]),
          account_masked: mask(dig(answer, ["iban"]))
        )

      {:error, _reason} ->
        {:error, {:malformed, :body}}
    end
  end
end
