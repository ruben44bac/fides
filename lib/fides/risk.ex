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

  @doc """
  The amount above which an analyst's approval needs a risk manager's
  countersignature, under a policy version of the country. Nil without a version.
  """
  @spec countersign_threshold(String.t(), Ecto.UUID.t() | nil) :: non_neg_integer() | nil
  def countersign_threshold(_country, nil), do: nil

  def countersign_threshold(country, policy_version_id) do
    with {:ok, version} <-
           Ash.get(Fides.Risk.PolicyVersion, policy_version_id,
             tenant: country,
             authorize?: false
           ),
         {:ok, %{countersign_above_minor: threshold}} <- cast_params(country, version.params) do
      threshold
    else
      _no_version -> nil
    end
  end
end
