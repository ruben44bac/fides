defmodule Fides.Risk.Engine.Result do
  @moduledoc """
  The decision with its trace: the outcome, the reason codes, what each rule said,
  and two SHA-256 hashes, one of the inputs and parameters and one of the whole
  decision, so replaying it later shows whether anything changed.
  """

  @enforce_keys [:outcome, :reason_codes, :rule_results, :inputs_hash, :hash]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          outcome: :approve | :review | :reject,
          reason_codes: [atom()],
          rule_results: [Fides.Risk.Engine.RuleResult.t()],
          inputs_hash: binary(),
          hash: binary()
        }
end
