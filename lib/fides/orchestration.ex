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

  @doc """
  Every fact found about an application, newest first, with the agent and tool that
  found each one. `case_facts/3` keeps only the current fact of each name.
  """
  @spec case_fact_history(String.t(), Ecto.UUID.t(), term()) ::
          {:ok, [struct()]} | {:error, term()}
  def case_fact_history(country, application_id, actor) do
    require Ash.Query

    Fides.Orchestration.CaseFact
    |> Ash.Query.filter(application_id == ^application_id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read(tenant: country, actor: actor)
  end

  @doc "Every run of an agent on an application, newest first."
  @spec agent_runs(String.t(), Ecto.UUID.t(), term()) :: {:ok, [struct()]} | {:error, term()}
  def agent_runs(country, application_id, actor) do
    require Ash.Query

    Fides.Orchestration.AgentRun
    |> Ash.Query.filter(application_id == ^application_id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read(tenant: country, actor: actor)
  end

  @job_states ~w(available scheduled executing retryable discarded)

  @doc """
  How many jobs each queue holds, by state: waiting to run, scheduled for later,
  running, waiting to retry, and given up on. Every configured queue appears, in the
  order of the configuration, with zeros when it is empty.
  """
  @spec queue_depths() :: [%{queue: atom(), counts: %{String.t() => non_neg_integer()}}]
  def queue_depths do
    require Ecto.Query

    counts =
      Oban.Job
      |> Ecto.Query.where([job], job.state in @job_states)
      |> Ecto.Query.group_by([job], [job.queue, job.state])
      |> Ecto.Query.select([job], {job.queue, job.state, count(job.id)})
      |> Fides.Platform.Repo.all()
      |> Enum.group_by(fn {queue, _state, _count} -> queue end)

    for {queue, _limit} <- Keyword.get(Application.get_env(:fides, Oban, []), :queues, []) do
      by_state =
        Map.new(Map.get(counts, Atom.to_string(queue), []), fn {_q, state, n} -> {state, n} end)

      %{queue: queue, counts: Map.new(@job_states, &{&1, Map.get(by_state, &1, 0)})}
    end
  end

  @doc "Applies, by a job, the data a provider delivered later for a recorded event."
  defdelegate provider_callback(country, provider, event, parsed),
    to: Fides.Orchestration.ProviderCallback,
    as: :enqueue
end
