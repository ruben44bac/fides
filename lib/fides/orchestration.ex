defmodule Fides.Orchestration do
  @moduledoc """
  Orchestration context: moves each application through its country's life cycle.

  Every write to an application enqueues a step, in the same transaction. The step
  runs what the life cycle declares on entering the current state; the agents it
  calls propose what comes next, and the orchestrator confirms a proposal only if the
  application is still at the version the agent saw. What the agents find is kept as
  facts of the case, and every agent run leaves a record.
  """

  use Fides.Platform.Domain,
    boundary: [
      deps: [
        Fides.Platform,
        Fides.Origination,
        Fides.Identity,
        Fides.Banking,
        Fides.Notifications,
        Fides.Risk
      ],
      exports: []
    ]

  resources do
    resource Fides.Orchestration.AgentRun do
      define :record_agent_run, action: :record
      define :list_agent_runs, action: :read
    end

    resource Fides.Orchestration.CaseFact do
      define :record_case_fact, action: :record
      define :list_case_facts, action: :read
    end
  end

  @doc "The facts of a case by name, each the latest one recorded."
  @spec case_facts(String.t(), Ecto.UUID.t(), term()) ::
          {:ok, %{String.t() => map()}} | {:error, term()}
  def case_facts(country, application_id, actor) do
    require Ash.Query

    Fides.Orchestration.CaseFact
    |> Ash.Query.filter(application_id == ^application_id)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read(tenant: country, actor: actor)
    |> case do
      {:ok, facts} -> {:ok, Map.new(facts, &{&1.name, &1.value})}
      {:error, error} -> {:error, error}
    end
  end

  @doc "Applies, by a job, the data a provider delivered later for a recorded event."
  defdelegate provider_callback(country, provider, event, parsed),
    to: Fides.Orchestration.ProviderCallback,
    as: :enqueue
end
