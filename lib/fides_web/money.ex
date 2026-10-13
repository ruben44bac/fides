defmodule FidesWeb.Money do
  @moduledoc """
  Amounts as people type them, in a currency's units with up to two decimals after a
  dot or a comma, turned into the minor units the domain keeps.
  """

  @amount ~r/^\d{1,13}(?:[.,]\d{1,2})?$/

  @doc """
  The minor units of an amount typed in units: `"25000"` and `"25000,5"` are
  `2_500_000` and `2_500_050`. Blank is `:blank`; anything else is `:error`.
  """
  @spec parse(String.t() | nil) :: {:ok, non_neg_integer()} | :blank | :error
  def parse(value) do
    case text(value) do
      nil -> :blank
      amount -> amount |> String.replace(" ", "") |> units_and_cents()
    end
  end

  @doc "An amount in minor units as units to type back: `2_500_050` is `25000.50`."
  @spec units(non_neg_integer()) :: String.t()
  def units(minor) when is_integer(minor) do
    cents = minor |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")
    if cents == "00", do: Integer.to_string(div(minor, 100)), else: "#{div(minor, 100)}.#{cents}"
  end

  defp units_and_cents(amount) do
    if Regex.match?(@amount, amount) do
      {units, cents} =
        case String.split(amount, ~r/[.,]/) do
          [units] -> {units, "00"}
          [units, cents] -> {units, String.pad_trailing(cents, 2, "0")}
        end

      {:ok, String.to_integer(units) * 100 + String.to_integer(cents)}
    else
      :error
    end
  end

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp text(_other), do: nil
end
