defmodule Fides.Risk.Engine.Policies.IT do
  @moduledoc """
  Italy: regular income. The bank must observe income in each of the recent months
  required and at least the minimum monthly income; otherwise it rejects.
  """

  @behaviour Fides.Risk.Engine.Policy

  alias Fides.Risk.Engine.RuleResult

  @impl true
  def country, do: "IT"

  @impl true
  def default_params do
    %{min_income_months: 6, min_monthly_income_minor: 120_000, countersign_above_minor: 5_000_000}
  end

  @impl true
  def evaluate(inputs, params) do
    reasons =
      Enum.filter(
        [
          inputs.income_months < params.min_income_months && :irregular_income,
          inputs.observed_income_minor < params.min_monthly_income_minor && :income_below_minimum
        ],
        & &1
      )

    RuleResult.new(:regular_income, :reject, reasons)
  end
end
