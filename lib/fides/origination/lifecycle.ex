defmodule Fides.Origination.Lifecycle do
  @moduledoc """
  The life of a credit application as data: its states and, for each country, the
  transitions between them, who may perform each one and under which condition.

  Actors are the system (the orchestrator), or a person: the applicant, an analyst
  or a risk manager. A person never performs a system transition, and the system
  never performs a person's. Final states have no way out.

  Two transitions depend on the countersign threshold of the country's policy: an
  analyst who approves above it sends the application to a risk manager for the
  second signature. The context carries `amount_minor` and `countersign_above_minor`;
  without them neither transition is available.

  Pure functions, so every rule can be checked without a database.
  """

  use Boundary, type: :strict, deps: [], exports: [Transition]

  alias Fides.Origination.Lifecycle.Transition

  @final [:approved, :rejected, :cancelled]
  @open [
    :submitted,
    :validating,
    :awaiting_bank_data,
    :evaluating,
    :in_review,
    :info_requested,
    :provider_error,
    :pending_countersign
  ]
  @actors [:system, :applicant, :analyst, :risk_manager]
  @countries ~w(ES PT IT MX CO BR)

  @base [
    {:submitted, :validating, [:system]},
    {:validating, :awaiting_bank_data, [:system]},
    {:awaiting_bank_data, :evaluating, [:system]},
    {:awaiting_bank_data, :provider_error, [:system]},
    {:provider_error, :awaiting_bank_data, [:system]},
    {:evaluating, :approved, [:system]},
    {:evaluating, :rejected, [:system]},
    {:evaluating, :in_review, [:system]},
    {:in_review, :approved, [:analyst], :within_countersign_threshold},
    {:in_review, :pending_countersign, [:analyst], :above_countersign_threshold},
    {:in_review, :rejected, [:analyst]},
    {:in_review, :info_requested, [:analyst]},
    # Reevaluation after a new policy version: only applications waiting for a person
    {:in_review, :evaluating, [:system]},
    # The applicant, or an analyst on their behalf, answers with a new revision
    {:info_requested, :validating, [:applicant, :analyst]},
    {:pending_countersign, :approved, [:risk_manager]},
    {:pending_countersign, :in_review, [:risk_manager]}
  ]

  @transitions Enum.map(@base, &Transition.new/1) ++
                 Enum.map(@open, &Transition.new({&1, :cancelled, [:applicant, :analyst]}))

  @spec states() :: [atom()]
  def states, do: @open ++ @final

  @spec final_states() :: [atom()]
  def final_states, do: @final

  @spec final?(atom()) :: boolean()
  def final?(state), do: state in @final

  @spec actors() :: [atom()]
  def actors, do: @actors

  @spec countries() :: [String.t()]
  def countries, do: @countries

  @doc "Every transition of a country's life cycle. All countries share the same one today."
  @spec transitions(String.t()) :: [Transition.t()]
  def transitions(country) when country in @countries, do: @transitions

  @doc "The states `actor` may move an application to from `state`."
  @spec available(String.t(), atom(), atom(), map()) :: [atom()]
  def available(country, state, actor, context \\ %{}) do
    for %Transition{from: ^state} = transition <- transitions(country),
        actor in transition.actors,
        guard_holds?(transition.guard, context),
        do: transition.to
  end

  @doc """
  Checks a transition. When it is not allowed, the error lists the states the actor
  may move to instead.
  """
  @spec transition(String.t(), atom(), atom(), atom(), map()) ::
          {:ok, atom()} | {:error, {:final_state, atom()} | {:not_allowed, [atom()]}}
  def transition(country, from, to, actor, context \\ %{}) do
    available = available(country, from, actor, context)

    cond do
      final?(from) -> {:error, {:final_state, from}}
      to in available -> {:ok, to}
      true -> {:error, {:not_allowed, available}}
    end
  end

  defp guard_holds?(nil, _context), do: true

  defp guard_holds?(guard, %{amount_minor: amount, countersign_above_minor: threshold})
       when is_integer(amount) and is_integer(threshold) do
    case guard do
      :within_countersign_threshold -> amount <= threshold
      :above_countersign_threshold -> amount > threshold
    end
  end

  defp guard_holds?(_guard, _context), do: false
end
