defmodule Fides.Risk do
  @moduledoc """
  Risk context: decides each credit application with a deterministic engine over
  versioned per-country policies, and keeps a record that can be reproduced.
  """

  use Fides.Platform.Domain,
    boundary: [deps: [Fides.Platform], exports: []]

  resources do
    resource Fides.Risk.PolicyVersion do
      define :propose_policy, action: :propose, args: [:params]
      define :publish_policy, action: :publish
      define :policy_in_force, action: :in_force, not_found_error?: false
      define :list_policy_versions, action: :read
    end
  end

  @doc "Evaluates canonical inputs with a policy's parameters."
  defdelegate evaluate(inputs, params), to: Fides.Risk.Engine

  @doc "The parameters of a country's first policy version."
  defdelegate default_params(country), to: Fides.Risk.Engine

  @doc "Checks a policy's parameters for a country, with atom keys once valid."
  defdelegate cast_params(country, params), to: Fides.Risk.Engine
end
