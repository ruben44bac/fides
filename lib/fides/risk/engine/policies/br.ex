defmodule Fides.Risk.Engine.Policies.BR do
  @moduledoc """
  Brazil: the credit score the bank reports, from 0 to 1000. From the approval score
  up approves, from the review score up goes to review, below it rejects. Applications
  carry no term or rate, so Brazil decides by score rather than repayment capacity.
  """

  @behaviour Fides.Risk.Engine.Policy

  alias Fides.Risk.Engine.RuleResult

  @impl true
  def country, do: "BR"

  @impl true
  def default_params do
    %{approve_min_score: 600, review_min_score: 450}
  end

  @impl true
  def check_params(%{approve_min_score: approve, review_min_score: review}) do
    cond do
      review > approve -> {:error, "review_min_score cannot be above approve_min_score"}
      approve > 1000 -> {:error, "approve_min_score cannot be above 1000, the highest score"}
      true -> :ok
    end
  end

  @impl true
  def evaluate(inputs, params) do
    cond do
      inputs.score >= params.approve_min_score ->
        RuleResult.new(:score, :approve, [])

      inputs.score >= params.review_min_score ->
        RuleResult.new(:score, :review, [:score_review_band])

      true ->
        RuleResult.new(:score, :reject, [:score_below_minimum])
    end
  end
end
