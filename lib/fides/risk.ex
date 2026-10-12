defmodule Fides.Risk do
  @moduledoc """
  Risk context: decides each credit application with a deterministic engine over
  versioned per-country policies, and keeps a record that can be reproduced.
  """

  use Fides.Platform.Domain,
    boundary: [deps: [Fides.Platform], exports: []]

  @doc "Evaluates canonical inputs with a policy's parameters."
  defdelegate evaluate(inputs, params), to: Fides.Risk.Engine

  @doc "The parameters of a country's first policy version."
  defdelegate default_params(country), to: Fides.Risk.Engine
end
