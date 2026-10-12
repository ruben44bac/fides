defmodule Fides.Risk.Engine.Policy do
  @moduledoc """
  What each country implements: its rule and the parameters of its first policy
  version. Every country's parameters also carry `countersign_above_minor`: an
  analyst's approval above that amount needs a risk manager's countersignature.
  """

  alias Fides.Risk.Engine.Inputs
  alias Fides.Risk.Engine.RuleResult

  @doc "ISO 3166-1 alpha-2 code of the country."
  @callback country() :: String.t()

  @doc "Thresholds of the country's first policy version, in minor units where they are amounts."
  @callback default_params() :: map()

  @doc "Checks the thresholds that only make sense together, such as bands in order."
  @callback check_params(params :: map()) :: :ok | {:error, String.t()}

  @doc "The country's own rule."
  @callback evaluate(Inputs.t(), params :: map()) :: RuleResult.t()
end
