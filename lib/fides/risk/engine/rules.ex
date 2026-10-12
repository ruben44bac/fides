defmodule Fides.Risk.Engine.Rules do
  @moduledoc """
  The rules every country applies before its own:

    * **Eligibility:** a valid document, an adult holder when the document tells, and
      a declared income above zero. Failing any rejects.
    * **History:** a rejection of the same holder within the window sends to review.
    * **Income consistency:** when the bank observes less income than declared,
      beyond the tolerance, an analyst decides. More observed income is no risk.
  """

  alias Fides.Risk.Engine.Inputs
  alias Fides.Risk.Engine.RuleResult

  @doc "Common parameters of the first policy version."
  @spec default_params() :: map()
  def default_params, do: %{history_window_days: 30, income_tolerance_percent: 15}

  @spec evaluate(Inputs.t(), map()) :: [RuleResult.t()]
  def evaluate(%Inputs{} = inputs, params) do
    [eligibility(inputs), history(inputs, params), income_consistency(inputs, params)]
  end

  defp eligibility(inputs) do
    reasons =
      Enum.filter(
        [
          not inputs.document_valid? && :invalid_document,
          inputs.adult? == false && :underage,
          inputs.declared_income_minor <= 0 && :no_declared_income
        ],
        & &1
      )

    RuleResult.new(:eligibility, :reject, reasons)
  end

  defp history(inputs, params) do
    recent? =
      inputs.previous_rejection_on != nil and
        Date.diff(inputs.evaluated_on, inputs.previous_rejection_on) < params.history_window_days

    RuleResult.new(:history, :review, if(recent?, do: [:recent_rejection], else: []))
  end

  defp income_consistency(inputs, params) do
    below_tolerance? =
      inputs.observed_income_minor * 100 <
        inputs.declared_income_minor * (100 - params.income_tolerance_percent)

    RuleResult.new(
      :income_consistency,
      :review,
      if(below_tolerance?, do: [:income_mismatch], else: [])
    )
  end
end
