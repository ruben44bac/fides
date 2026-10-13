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
      define :get_policy_version, action: :read, get_by: [:id]
      define :list_policy_versions, action: :read
    end

    resource Fides.Risk.DecisionRecord do
      define :record_decision, action: :record
      define :list_decisions, action: :read
    end
  end

  @doc """
  Decides an application with the policy version in force in its country and keeps
  the decision. `evaluation` carries the country, the application, its revision, the
  bank profile and the canonical inputs; the actor is who evaluates.
  """
  defdelegate decide(evaluation, opts), to: Fides.Risk.Decide, as: :run

  @doc "The latest decision on an application, or nil."
  defdelegate latest_decision(application_id, opts), to: Fides.Risk.Decide, as: :latest

  @doc "The decisions on an application, newest first."
  defdelegate decisions(country, application_id, actor), to: Fides.Risk.Decide, as: :list

  @doc """
  The rules that said something different in `decision` than in `previous`, the
  decision it replaces: another outcome, or other reason codes. None without a
  previous decision.
  """
  defdelegate changed_rules(decision, previous), to: Fides.Risk.Decide

  @doc "Evaluates canonical inputs with a policy's parameters."
  defdelegate evaluate(inputs, params), to: Fides.Risk.Engine

  @doc "The parameters of a country's first policy version."
  defdelegate default_params(country), to: Fides.Risk.Engine

  @doc "Checks a policy's parameters for a country, with atom keys once valid."
  defdelegate cast_params(country, params), to: Fides.Risk.Engine

  @doc """
  The amount above which an analyst's approval needs a risk manager's
  countersignature, under a policy version of the country. Nil without a version, or
  in a country without a countersignature.
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
