defmodule Fides.Banking.Adapters.Profile do
  @moduledoc """
  A bank profile in Fides' own terms, whatever the provider's format:

    * `observed_income_minor` and `total_debt_minor`: monthly income and total debt,
      in minor units of the country's currency;
    * `income_months`: recent months with income, out of the last six;
    * `score`: the provider's credit score, from 0 to 1000;
    * `account_masked`: the account reduced to its last four characters.

  The provider's answer itself is never kept.
  """

  @enforce_keys [
    :observed_income_minor,
    :total_debt_minor,
    :income_months,
    :score,
    :account_masked
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          observed_income_minor: non_neg_integer(),
          total_debt_minor: non_neg_integer(),
          income_months: 0..6,
          score: 0..1000,
          account_masked: String.t()
        }

  @doc """
  Builds a profile from already converted values, or names the first field whose
  value is missing or out of range.
  """
  @spec build(keyword()) :: {:ok, t()} | {:error, {:malformed, atom()}}
  def build(fields) do
    Enum.reduce_while(fields, {:ok, %{}}, fn {field, value}, {:ok, valid} ->
      if valid?(field, value),
        do: {:cont, {:ok, Map.put(valid, field, value)}},
        else: {:halt, {:error, {:malformed, field}}}
    end)
    |> case do
      {:ok, valid} -> {:ok, struct!(__MODULE__, valid)}
      error -> error
    end
  end

  defp valid?(field, value) when field in [:observed_income_minor, :total_debt_minor],
    do: is_integer(value) and value >= 0

  defp valid?(:income_months, value), do: is_integer(value) and value in 0..6
  defp valid?(:score, value), do: is_integer(value) and value in 0..1000
  defp valid?(:account_masked, value), do: is_binary(value)
  defp valid?(_field, _value), do: false
end
