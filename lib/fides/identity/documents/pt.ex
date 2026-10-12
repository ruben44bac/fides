defmodule Fides.Identity.Documents.PT do
  @moduledoc """
  Portugal. NIF: nine digits, the last one a modulo 11 check digit over the first
  eight weighted from 9 down to 2.
  """

  @behaviour Fides.Identity.Documents.Validator

  @impl true
  def country, do: "PT"

  @impl true
  def document_types, do: ["NIF"]

  @impl true
  def validate("NIF", document, _holder) do
    if document =~ ~r/^\d{9}$/ do
      {base, check} = String.split_at(document, 8)

      if check_digit(base) == String.to_integer(check),
        do: {:ok, nil},
        else: {:error, [:invalid_check_digit]}
    else
      {:error, [:invalid_format]}
    end
  end

  @doc "The check digit of the first eight digits of a NIF."
  @spec check_digit(String.t()) :: non_neg_integer()
  def check_digit(base) do
    sum =
      base
      |> String.to_charlist()
      |> Enum.with_index()
      |> Enum.reduce(0, fn {digit, index}, sum -> sum + (digit - ?0) * (9 - index) end)

    case 11 - rem(sum, 11) do
      check when check >= 10 -> 0
      check -> check
    end
  end
end
