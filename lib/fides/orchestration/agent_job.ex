defmodule Fides.Orchestration.AgentJob do
  @moduledoc """
  Runs an agent on an application, in the agent's own queue, and has the
  orchestrator confirm what it proposes. A job runs on the version of the application
  the step saw, and once per agent and version: a retry or a second worker on the same
  version confirms at most one move.
  """

  use Oban.Worker,
    queue: :orchestration,
    max_attempts: 5,
    unique: [keys: [:agent, :application_id, :lock_version], period: :infinity]

  alias Fides.Orchestration.Agents
  alias Fides.Orchestration.Assignment
  alias Fides.Orchestration.Orchestrator

  @doc "Enqueues `agent` on the application's current version."
  @spec enqueue(module(), struct()) :: :ok | {:error, term()}
  def enqueue(agent, application) do
    %{
      agent: agent.name(),
      application_id: application.id,
      country_code: application.country_code,
      lock_version: application.lock_version
    }
    |> new(queue: agent.queue())
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"agent" => name} = args} = job) do
    %{"application_id" => id, "lock_version" => version} = args

    with {:ok, agent} <- Agents.fetch(name),
         {:ok, %{lock_version: ^version} = application} <- Orchestrator.application(id) do
      run = %{job_id: job.id, attempt: job.attempt, started: System.monotonic_time(:millisecond)}
      proposal = agent.run(Assignment.new(application))
      Orchestrator.confirm(application, agent, proposal, run)
    else
      :error -> {:cancel, :unknown_agent}
      {:ok, _changed} -> {:cancel, :superseded}
      {:error, :not_found} -> {:cancel, :not_found}
      {:error, error} -> {:error, error}
    end
  end
end
