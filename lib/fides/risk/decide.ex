defmodule Fides.Risk.Decide do
  @moduledoc false
  # Decides an application with the policy version in force in its country, and keeps
  # the decision. A later decision on the same application replaces the previous one.

  require Ash.Query

  alias Fides.Risk.DecisionRecord
  alias Fides.Risk.Engine
  alias Fides.Risk.Engine.Inputs

  @spec run(map(), keyword()) :: {:ok, DecisionRecord.t()} | {:error, :no_policy | term()}
  def run(evaluation, opts) do
    country = evaluation.country
    opts = Keyword.put(opts, :tenant, country)

    with {:ok, version} <- version_in_force(opts),
         {:ok, params} <- Engine.cast_params(country, version.params),
         inputs = struct!(Inputs, Map.put(evaluation.inputs, :country, country)),
         {:ok, result} <- Engine.evaluate(inputs, params),
         {:ok, previous} <- latest(evaluation.application_id, opts) do
      Fides.Risk.record_decision(
        %{
          application_id: evaluation.application_id,
          revision_id: evaluation.revision_id,
          policy_version_id: version.id,
          bank_profile_id: evaluation.bank_profile_id,
          replaces_id: previous && previous.id,
          cause: if(previous, do: :reevaluation, else: :evaluation),
          inputs: Map.from_struct(inputs),
          inputs_hash: result.inputs_hash,
          rule_results: Enum.map(result.rule_results, &Map.from_struct/1),
          outcome: result.outcome,
          reason_codes: result.reason_codes,
          engine_sha: Fides.Platform.Build.code_sha(),
          hash: result.hash
        },
        opts
      )
    end
  end

  @doc "The latest decision on an application, or nil."
  @spec latest(Ecto.UUID.t(), keyword()) :: {:ok, DecisionRecord.t() | nil} | {:error, term()}
  def latest(application_id, opts) do
    DecisionRecord
    |> Ash.Query.filter(application_id == ^application_id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(opts)
  end

  defp version_in_force(opts) do
    case Fides.Risk.policy_in_force(opts) do
      {:ok, nil} -> {:error, :no_policy}
      other -> other
    end
  end
end
