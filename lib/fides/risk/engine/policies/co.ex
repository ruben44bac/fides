defmodule Fides.Risk.Engine.Policies.CO do
  @moduledoc """
  Colombia: the total debt the bank reports must stay within a multiple of the
  declared monthly income; otherwise it rejects.
  """

  @behaviour Fides.Risk.Engine.Policy

  alias Fides.Risk.Engine.RuleResult

  @impl true
  def country, do: "CO"

  @impl true
  def default_params do
    %{max_debt_income_multiple: 5}
  end

  @impl true
  def check_params(_params), do: :ok

  @impl true
  def evaluate(inputs, params) do
    reasons =
      if inputs.total_debt_minor > params.max_debt_income_multiple * inputs.declared_income_minor,
        do: [:debt_above_income_multiple],
        else: []

    RuleResult.new(:debt_to_income, :reject, reasons)
  end
end
