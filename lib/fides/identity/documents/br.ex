defmodule Fides.Identity.Documents.BR do
  @moduledoc """
  Brazil. CPF: eleven digits, the last two modulo 11 check digits. A CPF made of a
  single repeated digit passes the arithmetic but is never issued, so it is rejected.
  """

  @behaviour Fides.Identity.Documents.Validator

  @impl true
  def country, do: "BR"

  @impl true
  def document_types, do: ["CPF"]

  @impl true
  def validate("CPF", document, _holder) do
    cond do
      not (document =~ ~r/^\d{11}$/) ->
        {:error, [:invalid_format]}

      document =~ ~r/^(\d)\1{10}$/ ->
        {:error, [:repeated_digits]}

      true ->
        {base, checks} = String.split_at(document, 9)

        if check_digits(base) == checks,
          do: {:ok, nil},
          else: {:error, [:invalid_check_digit]}
    end
  end

  @doc "The two check digits of the first nine digits of a CPF."
  @spec check_digits(String.t()) :: String.t()
  def check_digits(base) do
    digits = base |> String.to_charlist() |> Enum.map(&(&1 - ?0))
    first = check_digit(digits)
    second = check_digit(digits ++ [first])
    "#{first}#{second}"
  end

  defp check_digit(digits) do
    top_weight = length(digits) + 1

    sum =
      digits
      |> Enum.with_index()
      |> Enum.reduce(0, fn {digit, index}, sum -> sum + digit * (top_weight - index) end)

    case rem(sum * 10, 11) do
      10 -> 0
      check -> check
    end
  end
end
