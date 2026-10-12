defmodule Fides.Risk.Engine do
  @moduledoc """
  Decides a credit application.

  The common rules apply in every country: eligibility, a recent rejection and the
  consistency between declared and observed income. Then comes the country's own
  rule. Each rule approves, sends to review or rejects, and the decision is the most
  severe of them: reject, then review, then approve.

  Rule logic is code and its thresholds are parameters, which come from a versioned
  policy. The engine is pure and deterministic: the same inputs and parameters always
  give the same result and the same hash.
  """

  use Boundary, type: :strict, deps: [], exports: [Inputs, Result, RuleResult]

  alias Fides.Risk.Engine.Inputs
  alias Fides.Risk.Engine.Policies
  alias Fides.Risk.Engine.Result
  alias Fides.Risk.Engine.Rules

  @policies [Policies.ES, Policies.PT, Policies.IT, Policies.MX, Policies.CO, Policies.BR]
  @severity %{approve: 0, review: 1, reject: 2}

  @doc "Countries with a policy."
  @spec countries() :: [String.t()]
  def countries, do: Enum.map(@policies, & &1.country())

  @doc "The parameters of a country's first policy version: common and country thresholds."
  @spec default_params(String.t()) :: {:ok, map()} | {:error, :unsupported_country}
  def default_params(country) do
    with {:ok, policy} <- policy(country) do
      {:ok, Map.merge(Rules.default_params(), policy.default_params())}
    end
  end

  @spec evaluate(Inputs.t(), map()) :: {:ok, Result.t()} | {:error, :unsupported_country}
  def evaluate(%Inputs{} = inputs, params) do
    with {:ok, policy} <- policy(inputs.country) do
      rule_results = Rules.evaluate(inputs, params) ++ [policy.evaluate(inputs, params)]
      outcome = rule_results |> Enum.map(& &1.outcome) |> Enum.max_by(&Map.fetch!(@severity, &1))

      {:ok,
       %Result{
         outcome: outcome,
         reason_codes: Enum.flat_map(rule_results, & &1.reason_codes),
         rule_results: rule_results,
         inputs_hash: hash({inputs, params}),
         hash: hash({inputs, params, rule_results, outcome})
       }}
    end
  end

  defp policy(country) do
    case Enum.find(@policies, &(&1.country() == country)) do
      nil -> {:error, :unsupported_country}
      policy -> {:ok, policy}
    end
  end

  defp hash(term), do: :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
end
