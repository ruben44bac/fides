defmodule Fides.Risk.Engine.Policies.ES do
  @moduledoc "Spain: an amount above the review threshold goes to manual review."

  @behaviour Fides.Risk.Engine.Policy

  alias Fides.Risk.Engine.RuleResult

  @impl true
  def country, do: "ES"

  @impl true
  def default_params do
    %{review_above_amount_minor: 2_000_000, countersign_above_minor: 5_000_000}
  end

  @impl true
  def check_params(_params), do: :ok

  @impl true
  def evaluate(inputs, params) do
    reasons =
      if inputs.amount_minor > params.review_above_amount_minor,
        do: [:amount_above_review_threshold],
        else: []

    RuleResult.new(:amount_review_threshold, :review, reasons)
  end
end
