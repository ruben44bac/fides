defmodule Fides.Risk.Engine.Policies.PT do
  @moduledoc """
  Portugal: the amount against the declared monthly income. Up to the approval
  multiple approves, up to the review multiple goes to review, above it rejects.
  """

  @behaviour Fides.Risk.Engine.Policy

  alias Fides.Risk.Engine.RuleResult

  @impl true
  def country, do: "PT"

  @impl true
  def default_params do
    %{
      approve_max_income_multiple: 6,
      review_max_income_multiple: 8,
      countersign_above_minor: 5_000_000
    }
  end

  @impl true
  def check_params(%{approve_max_income_multiple: approve, review_max_income_multiple: review})
      when approve <= review,
      do: :ok

  def check_params(_params),
    do: {:error, "approve_max_income_multiple cannot be above review_max_income_multiple"}

  @impl true
  def evaluate(inputs, params) do
    income = inputs.declared_income_minor

    cond do
      inputs.amount_minor <= params.approve_max_income_multiple * income ->
        RuleResult.new(:income_multiple, :approve, [])

      inputs.amount_minor <= params.review_max_income_multiple * income ->
        RuleResult.new(:income_multiple, :review, [:income_multiple_review_band])

      true ->
        RuleResult.new(:income_multiple, :reject, [:income_multiple_exceeded])
    end
  end
end
