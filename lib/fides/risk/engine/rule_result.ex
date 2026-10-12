defmodule Fides.Risk.Engine.RuleResult do
  @moduledoc "What one rule said about an application, with the reason codes behind it."

  @enforce_keys [:rule, :outcome, :reason_codes]
  defstruct @enforce_keys

  @type outcome :: :approve | :review | :reject
  @type t :: %__MODULE__{rule: atom(), outcome: outcome(), reason_codes: [atom()]}

  @doc "Approves when there are no reasons, otherwise gives `outcome` with them."
  @spec new(atom(), outcome(), [atom()]) :: t()
  def new(rule, outcome, reasons) do
    %__MODULE__{
      rule: rule,
      outcome: if(reasons == [], do: :approve, else: outcome),
      reason_codes: reasons
    }
  end
end
