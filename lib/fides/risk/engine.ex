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

  @doc "The names of a country's thresholds: the common ones first, then the country's own."
  @spec param_names(String.t()) :: {:ok, [atom()]} | {:error, :unsupported_country}
  def param_names(country) do
    with {:ok, policy} <- policy(country) do
      {:ok, common_param_names() ++ Enum.sort(Map.keys(policy.default_params()))}
    end
  end

  @doc "The names of the thresholds of the rules every country applies."
  @spec common_param_names() :: [atom()]
  def common_param_names, do: Enum.sort(Map.keys(Rules.default_params()))

  @doc """
  Checks the thresholds proposed for a country's policy: exactly the ones of its
  first version, each a non-negative integer, and consistent with each other. Keys
  may be atoms or strings, as they come back from the database.
  """
  @spec cast_params(String.t(), term()) :: {:ok, map()} | {:error, String.t()}
  def cast_params(country, params) when is_map(params) do
    with {:ok, policy} <- policy(country),
         {:ok, defaults} <- default_params(country),
         {:ok, params} <- known_thresholds(params, Map.keys(defaults)),
         :ok <- policy.check_params(params) do
      {:ok, params}
    else
      {:error, :unsupported_country} -> {:error, "#{country} has no policy"}
      {:error, message} -> {:error, message}
    end
  end

  def cast_params(_country, _params), do: {:error, "must be a map of thresholds"}

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

  # Names come from the country's own thresholds, so no atom is created from input
  defp known_thresholds(params, names) do
    expected = Map.new(names, &{Atom.to_string(&1), &1})
    given = Map.new(params, fn {key, value} -> {key_name(key), value} end)
    unknown = Map.keys(given) -- Map.keys(expected)
    missing = Map.keys(expected) -- Map.keys(given)
    invalid = for {name, value} <- given, not (is_integer(value) and value >= 0), do: name

    cond do
      unknown != [] -> {:error, "unknown thresholds: " <> list(unknown)}
      missing != [] -> {:error, "missing thresholds: " <> list(missing)}
      invalid != [] -> {:error, "thresholds must be non-negative integers: " <> list(invalid)}
      true -> {:ok, Map.new(given, fn {name, value} -> {Map.fetch!(expected, name), value} end)}
    end
  end

  defp key_name(key) when is_binary(key), do: key
  defp key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp key_name(key), do: inspect(key)

  defp list(names), do: names |> Enum.sort() |> Enum.join(", ")

  defp hash(term), do: :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
end
