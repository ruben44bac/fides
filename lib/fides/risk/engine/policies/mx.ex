defmodule Fides.Risk.Engine.Policies.MX do
  @moduledoc """
  Mexico: the declared monthly income must reach a share of the amount requested;
  otherwise it rejects.
  """

  @behaviour Fides.Risk.Engine.Policy

  alias Fides.Risk.Engine.RuleResult

  @impl true
  def country, do: "MX"

  @impl true
  def default_params do
    %{min_income_percent_of_amount: 20, countersign_above_minor: 100_000_000}
  end

  @impl true
  def check_params(_params), do: :ok

  @impl true
  def evaluate(inputs, params) do
    reasons =
      if inputs.declared_income_minor * 100 <
           inputs.amount_minor * params.min_income_percent_of_amount,
         do: [:income_below_amount_share],
         else: []

    RuleResult.new(:income_to_amount, :reject, reasons)
  end
end
