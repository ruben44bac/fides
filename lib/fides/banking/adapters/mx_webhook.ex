defmodule Fides.Banking.Adapters.MxWebhook do
  @moduledoc """
  Mexico's provider answers later, through a signed webhook. Its body carries the
  event's identity and the profile, with amounts as JSON numbers in pesos with up to
  two decimals. The numbers are read as decimals, never as floats.

      {"event_id": "evt_...", "sequence": 3, "request_id": "...",
       "perfil": {"ingreso_mensual": 30000.50, "deuda_total": 120000.00,
                  "meses_con_ingreso": 6, "score": 690, "clabe": "0020100..."}}
  """

  @behaviour Fides.Banking.Adapters.Adapter

  import Fides.Banking.Adapters.Values

  alias Fides.Banking.Adapters.Profile

  @impl true
  def key, do: "mx_webhook"

  @impl true
  def parse(body) do
    case Jason.decode(body, floats: :decimals) do
      {:ok, %{"perfil" => profile}} ->
        Profile.build(
          observed_income_minor: amount(normalize(dig(profile, ["ingreso_mensual"]))),
          total_debt_minor: amount(normalize(dig(profile, ["deuda_total"]))),
          income_months: dig(profile, ["meses_con_ingreso"]),
          score: dig(profile, ["score"]),
          account_masked: mask(dig(profile, ["clabe"]))
        )

      _other ->
        {:error, {:malformed, :body}}
    end
  end

  @doc """
  The event's identity: its id, its sequence number and the request it answers. The
  webhook endpoint uses it to drop repeated events and reorder late ones.
  """
  @spec envelope(binary()) ::
          {:ok, %{event_id: String.t(), sequence: non_neg_integer(), request_id: String.t()}}
          | {:error, {:malformed, :body}}
  def envelope(body) do
    case Jason.decode(body) do
      {:ok, %{"event_id" => event_id, "sequence" => sequence, "request_id" => request_id}}
      when is_binary(event_id) and is_integer(sequence) and sequence >= 0 and
             is_binary(request_id) ->
        {:ok, %{event_id: event_id, sequence: sequence, request_id: request_id}}

      _other ->
        {:error, {:malformed, :body}}
    end
  end

  # Whole numbers arrive as integers even when decimals are read as Decimal
  defp normalize(number) when is_integer(number), do: Decimal.new(number)
  defp normalize(value), do: value
end
