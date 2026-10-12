defmodule Fides.Origination.Seeds do
  @moduledoc """
  Writes each country's life cycle to the database from the code: its states and the
  transitions between them, which the database then enforces on every application.

  Rows the code no longer declares are removed. A state that still holds applications
  cannot be removed: the seed then fails before changing anything, and names the
  states in use. Running it again leaves the same rows.
  """

  require Ash.Query

  alias Fides.Origination
  alias Fides.Origination.CreditApplication
  alias Fides.Origination.Lifecycle
  alias Fides.Origination.LifecycleState
  alias Fides.Origination.LifecycleTransition
  alias Fides.Platform.AuditContext
  alias Fides.Platform.SystemActor

  @type graph :: %{states: [atom()], transitions: [{atom(), atom()}]}

  @doc "Each country's states and transitions, as the code declares them."
  @spec graphs() :: %{String.t() => graph()}
  def graphs do
    Map.new(Lifecycle.countries(), fn country ->
      transitions =
        for transition <- Lifecycle.transitions(country),
            uniq: true,
            do: {transition.from, transition.to}

      {country, %{states: Lifecycle.states(country), transitions: transitions}}
    end)
  end

  @doc "Writes `graphs`, by default the code's, to the database."
  @spec run(%{String.t() => graph()}) :: :ok
  def run(graphs \\ graphs()) do
    actor = SystemActor.new(:seeds)
    context = AuditContext.new(actor: SystemActor.audit_id(actor), reason: "seed life cycles")

    changes =
      Map.new(graphs, fn {country, graph} -> {country, changes(country, graph, actor)} end)

    in_use =
      for {country, %{retire_states: states}} <- changes,
          state <- states,
          holds_applications?(country, state.state, actor),
          do: "#{country} #{state.state}"

    if in_use != [] do
      raise "cannot remove states that still hold applications: #{Enum.join(in_use, ", ")}"
    end

    for {country, country_changes} <- changes,
        Enum.any?(Map.values(country_changes), &(&1 != [])) do
      AuditContext.run(%{context | country: country}, fn ->
        write(country, country_changes, actor)
      end)
    end

    :ok
  end

  defp changes(country, graph, actor) do
    opts = [tenant: country, actor: actor]
    states = Origination.list_lifecycle_states!(opts)
    transitions = Origination.list_lifecycle_transitions!(opts)
    existing_states = Enum.map(states, & &1.state)
    existing_transitions = Enum.map(transitions, &{&1.from_state, &1.to_state})

    %{
      add_states: graph.states -- existing_states,
      retire_transitions:
        Enum.reject(transitions, &({&1.from_state, &1.to_state} in graph.transitions)),
      retire_states: Enum.reject(states, &(&1.state in graph.states)),
      add_transitions: graph.transitions -- existing_transitions
    }
  end

  defp holds_applications?(country, state, actor) do
    CreditApplication
    |> Ash.Query.filter(state == ^state)
    |> Ash.exists?(tenant: country, actor: actor)
  end

  # New states come before the transitions that use them, and stale transitions go
  # before the states they point at
  defp write(country, changes, actor) do
    opts = [tenant: country, actor: actor]

    {:ok, :ok} =
      Ash.transact(
        [LifecycleState, LifecycleTransition],
        fn ->
          for state <- changes.add_states, do: Origination.seed_lifecycle_state!(state, opts)

          for row <- changes.retire_transitions,
              do: Origination.retire_lifecycle_transition!(row, opts)

          for row <- changes.retire_states, do: Origination.retire_lifecycle_state!(row, opts)

          for {from, to} <- changes.add_transitions,
              do: Origination.seed_lifecycle_transition!(from, to, opts)

          :ok
        end,
        tenant: country
      )
  end
end
