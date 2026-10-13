defmodule Mocks.Providers do
  @moduledoc """
  Six simulated bank providers, one per country, each answering in its own format,
  as the real ones would:

  | Adapter      | Format                                                  |
  | ------------ | ------------------------------------------------------- |
  | `es_json`    | JSON, amounts in cents                                  |
  | `pt_json`    | JSON, Portuguese fields, amounts as "2.500,00"          |
  | `it_xml`     | XML, amounts with a decimal point                       |
  | `mx_webhook` | Accepts with 202 and delivers the profile by webhook    |
  | `co_json`    | JSON, whole pesos, reports the total debt               |
  | `br_json`    | JSON, amounts in centavos, a score from 0 to 1000       |

  A document always gets the same profile, derived from a hash of it, so a demo can
  pick its holders. The score takes the last digit of that hash: documents hashing to
  0 or 1 score low, 2 to 4 land in the middle, the rest score high.
  """

  @adapters ~w(es_json pt_json it_xml mx_webhook co_json br_json)

  @type profile :: %{
          income_units: pos_integer(),
          debt_units: non_neg_integer(),
          months: 0..6,
          score: 0..1000,
          account: String.t()
        }

  @spec adapters() :: [String.t()]
  def adapters, do: @adapters

  @doc "The profile of a document, the same every time, in whole units of a monthly income."
  @spec profile(String.t()) :: profile()
  def profile(document) do
    <<income::16, debt::16, months::8, pick::8, account::32, _rest::binary>> =
      :crypto.hash(:sha256, document)

    %{
      income_units: 800 + rem(income, 5_200),
      debt_units: rem(debt, 20_000),
      months: if(rem(months, 10) == 0, do: rem(months, 7), else: 6),
      score: score(rem(pick, 10)),
      account: account |> Integer.to_string() |> String.pad_leading(10, "0")
    }
  end

  @doc "The provider's answer for a profile: the body and its content type."
  @spec answer(String.t(), profile()) :: {String.t(), String.t()}
  def answer("es_json", profile) do
    json(%{
      cliente: %{
        iban:
          "ES91 2100 0418 4502 #{String.slice(profile.account, 0, 4)} #{String.slice(profile.account, 4, 4)}",
        deuda_total_centimos: profile.debt_units * 100,
        ingresos: %{
          mensual_centimos: profile.income_units * 100,
          meses_con_ingresos: profile.months
        }
      },
      puntuacion: profile.score
    })
  end

  def answer("pt_json", profile) do
    json(%{
      rendimento_mensal: portuguese(profile.income_units),
      divida_total: portuguese(profile.debt_units),
      meses_com_rendimento: profile.months,
      pontuacao: profile.score,
      iban: "PT50 0002 0123 1234 5678 #{String.slice(profile.account, 0, 4)} 4"
    })
  end

  def answer("it_xml", profile) do
    {"""
     <?xml version="1.0" encoding="UTF-8"?>
     <profilo>
       <reddito_mensile valuta="EUR">#{profile.income_units}.00</reddito_mensile>
       <debito_totale valuta="EUR">#{profile.debt_units}.00</debito_totale>
       <mesi_con_reddito>#{profile.months}</mesi_con_reddito>
       <punteggio>#{profile.score}</punteggio>
       <iban>IT60X054281110100000#{String.slice(profile.account, 0, 7)}</iban>
     </profilo>
     """, "application/xml"}
  end

  def answer("co_json", profile) do
    json(%{
      ingreso_mensual_pesos: profile.income_units * 1_800,
      deuda_total_pesos: profile.debt_units * 1_800,
      meses_con_ingreso: profile.months,
      puntaje: profile.score,
      cuenta: "123-#{String.slice(profile.account, 0, 6)}-01"
    })
  end

  def answer("br_json", profile) do
    json(%{
      rendaMensalCentavos: profile.income_units * 5 * 100,
      dividaTotalCentavos: profile.debt_units * 5 * 100,
      mesesComRenda: profile.months,
      score: profile.score,
      conta: %{agencia: "0001", numero: "#{String.slice(profile.account, 0, 6)}-7"}
    })
  end

  @doc "What Mexico's provider delivers later: the event, the request it answers and the profile, in pesos."
  @spec mexican_event(String.t(), String.t(), non_neg_integer(), profile()) :: String.t()
  def mexican_event(event_id, request_id, sequence, profile) do
    {body, _type} =
      json(%{
        event_id: event_id,
        sequence: sequence,
        request_id: request_id,
        perfil: %{
          ingreso_mensual: profile.income_units * 10 + 0.5,
          deuda_total: profile.debt_units * 10,
          meses_con_ingreso: profile.months,
          score: profile.score,
          clabe: "0020100#{profile.account}7"
        }
      })

    body
  end

  @doc "An answer in the provider's format that Fides cannot read."
  @spec malformed(String.t()) :: {String.t(), String.t()}
  def malformed("it_xml"),
    do: {"<profilo><reddito_mensile>molto</reddito_mensile>", "application/xml"}

  def malformed(_adapter), do: json(%{unexpected: "shape", puntuacion: "high"})

  defp score(0), do: 380
  defp score(1), do: 430
  defp score(pick) when pick in 2..4, do: 500 + pick * 20
  defp score(pick), do: 650 + pick * 25

  defp json(term), do: {Jason.encode!(term), "application/json"}

  # Portuguese amounts: a dot for thousands and a comma for the decimals
  defp portuguese(units) do
    units
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1.")
    |> String.reverse()
    |> Kernel.<>(",00")
  end
end
