defmodule Fides.Banking.Adapters.Values do
  @moduledoc false
  # Conversions shared by the adapters. Amounts never go through floats, and every
  # conversion returns :error instead of raising on an unexpected value.

  @doc "The value at a path of nested maps, or nil."
  def dig(term, []), do: term
  def dig(%{} = map, [key | rest]), do: dig(Map.get(map, key), rest)
  def dig(_term, _path), do: nil

  @doc "A decimal amount written as text, such as 2.500,00, in minor units."
  def amount(text, decimal: decimal, thousands: thousands) when is_binary(text) do
    pattern =
      ~r/^(?<integer>\d{1,3}(?:#{Regex.escape(thousands)}\d{3})*|\d+)(?:#{Regex.escape(decimal)}(?<fraction>\d{1,2}))?$/

    case Regex.named_captures(pattern, String.trim(text)) do
      %{"integer" => integer, "fraction" => fraction} ->
        units = integer |> String.replace(thousands, "") |> String.to_integer()
        units * 100 + String.to_integer(String.pad_trailing(fraction, 2, "0"))

      nil ->
        :error
    end
  end

  def amount(_value, _separators), do: :error

  @doc "A decimal number with at most two decimals, in minor units."
  def amount(%Decimal{} = number) do
    minor = Decimal.mult(number, 100)

    if Decimal.integer?(minor) and not Decimal.negative?(minor),
      do: Decimal.to_integer(minor),
      else: :error
  end

  def amount(_value), do: :error

  @doc "Whole units, such as Colombian pesos, in minor units."
  def whole_units(units) when is_integer(units) and units >= 0, do: units * 100
  def whole_units(_value), do: :error

  @doc "An integer written as text."
  def integer(text) when is_binary(text) do
    case Integer.parse(String.trim(text)) do
      {integer, ""} -> integer
      _other -> :error
    end
  end

  def integer(_value), do: :error

  @doc "An account reduced to its last four letters or digits."
  def mask(account) when is_binary(account) do
    case String.replace(account, ~r/[^0-9A-Za-z]/, "") do
      characters when byte_size(characters) >= 4 -> "****" <> String.slice(characters, -4, 4)
      _short -> :error
    end
  end

  def mask(_value), do: :error
end
