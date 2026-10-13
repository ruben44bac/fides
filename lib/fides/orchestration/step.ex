defmodule Fides.Orchestration.Step do
  @moduledoc """
  The orchestrator's step after each write to an application, which the database
  enqueues in the same transaction as the write.

  A step only acts on the version whose write enqueued it: if the application has
  changed since, a newer step is on its way, and this one is dropped. Otherwise it
  runs what the country's life cycle declares on entering the current state: its own
  move to the next state, an agent's job in the agent's queue, a retry back to an
  earlier state, scheduled for later, or the timeout of a provider's webhook, after
  which the application is in provider_error. Effects the orchestrator cannot run yet
  wait.
  """

  use Oban.Worker, queue: :orchestration, max_attempts: 20

  alias Fides.Orchestration.AgentJob
  alias Fides.Orchestration.Agents
  alias Fides.Orchestration.DelayedMove
  alias Fides.Orchestration.Orchestrator
  alias Fides.Origination

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"application_id" => id, "lock_version" => version}}) do
    case Orchestrator.application(id) do
      {:ok, %{lock_version: ^version} = application} -> run_effects(application)
      {:ok, _changed} -> {:cancel, :superseded}
      {:error, :not_found} -> {:cancel, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  defp run_effects(application) do
    application.country_code
    |> Origination.life_cycle_effects()
    |> Map.fetch!(application.state)
    |> Enum.reduce_while(:ok, fn effect, :ok ->
      case run(effect, application) do
        :ok -> {:cont, :ok}
        other -> {:halt, other}
      end
    end)
  end

  defp run({:transition, to}, application) do
    case Orchestrator.move(application, to, "entering #{to}") do
      {:ok, _moved} -> :ok
      {:error, :superseded} -> {:cancel, :superseded}
      {:error, error} -> {:error, error}
    end
  end

  defp run({:agent, name}, application) do
    case Agents.fetch(name) do
      {:ok, agent} -> AgentJob.enqueue(agent, application)
      :error -> :ok
    end
  end

  defp run({:retry, to}, application),
    do: DelayedMove.schedule(application, to, setting(:retry_after, 300))

  defp run({:timeout, _name}, application),
    do: DelayedMove.schedule(application, :provider_error, setting(:callback_timeout, 600))

  defp run(_not_yet, _application), do: :ok

  defp setting(key, default),
    do: :fides |> Application.get_env(Fides.Orchestration, []) |> Keyword.get(key, default)
end
