defmodule Fides.Origination.Lifecycle do
  @moduledoc """
  The life of a credit application as data: for each country, its states, the
  transitions between them, who may make each one and under which condition, and what
  runs on entering each state.

  Every country has the base cycle plus what its variant declares
  (`Fides.Origination.Lifecycle.Variant`): how its bank data arrives, whether a large
  approval needs a countersignature, and anything of its own. The seeds write the
  same graph to the database, which refuses any other change of state.

  Actors are the system (the orchestrator), or a person: the applicant, an analyst
  or a risk manager. A person never performs a system transition, and the system
  never performs a person's. Final states have no way out.

  In countries with a countersignature, two transitions depend on the threshold of
  the country's policy: an analyst who approves above it sends the application to a
  risk manager for the second signature. The context carries `amount_minor` and
  `countersign_above_minor`; without them neither transition is available.

  Pure functions, so every rule can be checked without a database.
  """

  use Boundary, type: :strict, deps: [], exports: [Transition, Diagram]

  alias Fides.Origination.Lifecycle.Transition
  alias Fides.Origination.Lifecycle.Variants

  @variants [Variants.ES, Variants.PT, Variants.IT, Variants.MX, Variants.CO, Variants.BR]

  @final [:approved, :rejected, :cancelled]
  # Every state some country has, in the order an application meets them
  @states [
            :submitted,
            :validating,
            :awaiting_bank_data,
            :awaiting_bank_callback,
            :evaluating,
            :in_review,
            :info_requested,
            :provider_error,
            :pending_countersign
          ] ++ @final
  @actors [:system, :applicant, :analyst, :risk_manager]

  # The cycle in order. A transition marked `only:` belongs to the countries with that
  # trait: `:sync` or `:async` bank data, and `:countersign` or `:single_approval`.
  @cycle [
    {:submitted, :validating, [:system]},
    {:validating, :awaiting_bank_data, [:system]},
    {:awaiting_bank_data, :evaluating, [:system], only: :sync},
    # The provider accepts the request; its webhook, or the timeout, moves on
    {:awaiting_bank_data, :awaiting_bank_callback, [:system], only: :async},
    {:awaiting_bank_callback, :evaluating, [:system], only: :async},
    {:awaiting_bank_callback, :provider_error, [:system], only: :async},
    {:awaiting_bank_data, :provider_error, [:system]},
    {:provider_error, :awaiting_bank_data, [:system]},
    {:evaluating, :approved, [:system]},
    {:evaluating, :rejected, [:system]},
    {:evaluating, :in_review, [:system]},
    {:in_review, :approved, [:analyst], only: :single_approval},
    {:in_review, :approved, [:analyst], only: :countersign, guard: :within_countersign_threshold},
    {:in_review, :pending_countersign, [:analyst],
     only: :countersign, guard: :above_countersign_threshold},
    {:in_review, :rejected, [:analyst]},
    {:in_review, :info_requested, [:analyst]},
    # Reevaluation after a new policy version: only applications waiting for a person
    {:in_review, :evaluating, [:system]},
    # The applicant, or an analyst on their behalf, answers with a new revision
    {:info_requested, :validating, [:applicant, :analyst]},
    {:pending_countersign, :approved, [:risk_manager], only: :countersign},
    {:pending_countersign, :in_review, [:risk_manager], only: :countersign}
  ]

  # What runs on entering each state, unless the country's variant says otherwise
  @effects %{
    submitted: [transition: :validating],
    validating: [agent: :intake],
    awaiting_bank_data: [agent: :banking],
    awaiting_bank_callback: [timeout: :bank_callback],
    evaluating: [agent: :risk],
    in_review: [queue: :review, capability: :case_brief],
    info_requested: [webhook: :info_requested, notice: :info_requested],
    provider_error: [retry: :awaiting_bank_data, alert: :provider_error],
    pending_countersign: [queue: :countersign],
    approved: [webhook: :approved, notice: :approved],
    rejected: [webhook: :rejected, notice: :rejected],
    cancelled: []
  }

  @typedoc """
  Something that runs on entering a state: the orchestrator's own move, an agent, a
  scheduled timeout, a scheduled retry back to the state it names, a work queue, an AI
  capability, a signed webhook, a notice to the applicant or an alert on the console.
  """
  @type effect ::
          {:transition
           | :agent
           | :timeout
           | :retry
           | :queue
           | :capability
           | :webhook
           | :notice
           | :alert, atom()}

  @spec countries() :: [String.t()]
  def countries, do: Enum.map(@variants, & &1.country())

  @doc "Every state some country has; `states/1` gives a country's own."
  @spec states() :: [atom()]
  def states, do: @states

  @doc "The states of a country's life cycle, in the order an application meets them."
  @spec states(String.t()) :: [atom()]
  def states(country) do
    used =
      for %Transition{} = transition <- transitions(country), do: [transition.from, transition.to]

    Enum.filter(@states, &(&1 in List.flatten(used)))
  end

  @spec final_states() :: [atom()]
  def final_states, do: @final

  @spec final?(atom()) :: boolean()
  def final?(state), do: state in @final

  @spec actors() :: [atom()]
  def actors, do: @actors

  @doc "How a country's bank data arrives: with the request, or later through a webhook."
  @spec bank_data(String.t()) :: :sync | :async
  def bank_data(country), do: variant!(country).bank_data()

  @doc "Whether a country's large approvals need a risk manager's countersignature."
  @spec countersign?(String.t()) :: boolean()
  def countersign?(country), do: variant!(country).countersign?()

  @doc "Every transition of a country's life cycle. Every open state can be cancelled."
  @spec transitions(String.t()) :: [Transition.t()]
  def transitions(country) do
    variant = variant!(country)

    traits = [
      variant.bank_data(),
      if(variant.countersign?(), do: :countersign, else: :single_approval)
    ]

    moves =
      for spec <- @cycle ++ own(variant, :transitions, []), belongs?(spec, traits) do
        spec |> without_trait() |> Transition.new()
      end

    open =
      for %Transition{from: from, to: to} <- moves,
          state <- [from, to],
          not final?(state),
          uniq: true,
          do: state

    moves ++ Enum.map(open, &Transition.new({&1, :cancelled, [:applicant, :analyst]}))
  end

  @doc """
  What runs on entering each state of a country. Every state of the country has an
  entry, empty when nothing runs.
  """
  @spec effects(String.t()) :: %{atom() => [effect()]}
  def effects(country) do
    @effects
    |> Map.merge(own(variant!(country), :effects, %{}))
    |> Map.take(states(country))
  end

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

  defp variant!(country) do
    Enum.find(@variants, &(&1.country() == country)) ||
      raise ArgumentError, "#{inspect(country)} has no life cycle"
  end

  # A variant declares transitions and effects of its own only when it has them
  defp own(variant, callback, default) do
    if function_exported?(variant, callback, 0), do: apply(variant, callback, []), else: default
  end

  defp belongs?({_from, _to, _actors, opts}, traits) when is_list(opts),
    do: Keyword.get(opts, :only) in [nil | traits]

  defp belongs?(_spec, _traits), do: true

  defp without_trait({from, to, actors, opts}) when is_list(opts),
    do: {from, to, actors, Keyword.get(opts, :guard)}

  defp without_trait(spec), do: spec

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
