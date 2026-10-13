defmodule Fides.Orchestration.Orchestrator do
  @moduledoc """
  The system's only writer of an application's state. It moves an application only
  while it is still at the version whoever proposed the move saw: otherwise the update
  finds no row, and the proposal is dropped as superseded, since the write that
  changed the application enqueued its own step.

  It confirms an agent's proposal together with the facts the agent found, in one
  transaction, and records every agent run, whatever came of it.
  """

  require Logger

  alias Fides.Orchestration
  alias Fides.Orchestration.AgentRun
  alias Fides.Orchestration.Assignment
  alias Fides.Orchestration.CaseFact
  alias Fides.Origination
  alias Fides.Platform.AuditContext
  alias Fides.Platform.SystemActor

  @actor SystemActor.new(:orchestrator)

  @doc "The application with `id`, in whichever country it is."
  @spec application(Ecto.UUID.t()) :: {:ok, struct()} | {:error, :not_found | term()}
  def application(id) do
    case Origination.find_application(id, actor: @actor) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, application} -> {:ok, application}
      {:error, error} -> {:error, error}
    end
  end

  @doc "Moves the application to `to`, if it is still at the version it was read at."
  @spec move(struct(), atom(), String.t()) :: {:ok, struct()} | {:error, :superseded | term()}
  def move(application, to, reason) do
    AuditContext.run(context(reason), fn -> transition(application, to) end)
  end

  @doc """
  Confirms what an agent proposed for `application`, as read before the agent ran,
  and records the run. `run` carries the job's id and attempt, and when the agent
  started, in monotonic milliseconds.
  """
  @spec confirm(struct(), module(), Fides.Orchestration.Agent.proposal(), map()) ::
          :ok | {:error, term()}
  def confirm(application, agent, proposal, run) do
    AuditContext.run(context("#{agent.name()} #{describe(proposal)}"), fn ->
      apply_proposal(application, agent, proposal, run)
    end)
  end

  defp apply_proposal(application, agent, {:advance, %{to: to} = advance}, run) do
    confirmed =
      Ash.transact([AgentRun, CaseFact], fn ->
        confirm_advance(application, agent, advance, run)
      end)

    # A failed update rolls the whole transaction back with its own error
    case confirmed do
      {:ok, :ok} ->
        :ok

      {:error, error} ->
        if stale?(error) do
          record_run!(application, agent, run, :superseded, to: to)
          :ok
        else
          record_run!(application, agent, run, :retry, to: to, reason: message(error))
          {:error, error}
        end
    end
  end

  defp apply_proposal(application, agent, {:retry, reason}, run) do
    record_run!(application, agent, run, :retry, reason: reason)
    {:error, reason}
  end

  defp apply_proposal(application, agent, {:escalate, reason}, run) do
    Logger.warning("#{agent.name()} escalated application #{application.id}: #{reason}")
    record_run!(application, agent, run, :escalate, reason: reason)
    :ok
  end

  # The move, the facts and the run commit together, or not at all
  defp confirm_advance(application, agent, %{to: to} = advance, run) do
    with {:ok, _moved} <- transition(application, to) do
      for {name, value} <- advance.facts do
        record_fact!(application, agent, advance.tool, name, value)
      end

      record_run!(application, agent, run, :advance, to: to)
      :ok
    end
  end

  defp transition(application, to) do
    application
    |> Origination.transition_application(to, application.lock_version, %{},
      tenant: application.country_code,
      actor: @actor
    )
    |> case do
      {:ok, moved} -> {:ok, moved}
      {:error, error} -> if stale?(error), do: {:error, :superseded}, else: {:error, error}
    end
  end

  defp stale?(%{errors: errors}),
    do: Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))

  defp stale?(_error), do: false

  defp record_fact!(application, agent, tool, name, value) do
    Orchestration.record_case_fact!(
      %{
        application_id: application.id,
        name: Atom.to_string(name),
        value: value,
        agent: agent.name(),
        tool: tool,
        lock_version: application.lock_version
      },
      tenant: application.country_code,
      actor: @actor
    )
  end

  defp record_run!(application, agent, run, outcome, opts) do
    Orchestration.record_agent_run!(
      %{
        application_id: application.id,
        agent: agent.name(),
        agent_version: agent.version(),
        job_id: run.job_id,
        attempt: run.attempt,
        lock_version: application.lock_version,
        input_hash: application |> Assignment.new() |> Assignment.hash(),
        outcome: outcome,
        proposed_state: opts[:to],
        reason: opts[:reason],
        duration_ms: System.monotonic_time(:millisecond) - run.started
      },
      tenant: application.country_code,
      actor: @actor
    )
  end

  defp context(reason), do: [actor: SystemActor.audit_id(@actor), reason: reason]

  defp describe({:advance, %{to: to}}), do: "proposed #{to}"
  defp describe({:retry, _reason}), do: "asked to retry"
  defp describe({:escalate, _reason}), do: "escalated"

  defp message(error) when is_exception(error), do: Exception.message(error)
  defp message(error), do: inspect(error)
end
