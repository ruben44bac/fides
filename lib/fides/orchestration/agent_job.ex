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
  alias Fides.Platform.AgentActor
  alias Fides.Platform.AuditContext

  @doc "Enqueues `agent` on the application's current version."
  @spec enqueue(module(), struct()) :: :ok | {:error, term()}
  def enqueue(agent, application) do
    %{
      agent: agent.name(),
      application_id: application.id,
      country_code: application.country_code,
      lock_version: application.lock_version
    }
    |> new(queue: agent.queue(Assignment.new(application)))
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
      assignment = Assignment.new(application)

      proposal =
        assignment
        |> run_as_agent(agent)
        |> last_attempt(agent, assignment, job)

      Orchestrator.confirm(application, agent, proposal, run)
    else
      :error -> {:cancel, :unknown_agent}
      {:ok, _changed} -> {:cancel, :superseded}
      {:error, :not_found} -> {:cancel, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  # What an agent writes with its tools, such as a provider's answer, is its own
  defp run_as_agent(assignment, agent) do
    actor = agent.name() |> AgentActor.new() |> AgentActor.audit_id()

    AuditContext.run([actor: actor, reason: "#{agent.name()} run"], fn ->
      agent.run(assignment)
    end)
  end

  defp last_attempt({:retry, reason}, agent, assignment, %{attempt: attempt, max_attempts: max})
       when attempt >= max do
    if function_exported?(agent, :exhausted, 2),
      do: agent.exhausted(assignment, reason),
      else: {:escalate, reason}
  end

  defp last_attempt(proposal, _agent, _assignment, _job), do: proposal
end
