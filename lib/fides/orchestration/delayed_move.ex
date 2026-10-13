defmodule Fides.Orchestration.DelayedMove do
  @moduledoc """
  A move the orchestrator makes later, such as a retry from provider_error back to
  the bank data. It only moves the application if it is still at the version that
  scheduled it: anything that changed the application since has enqueued its own step.
  """

  use Oban.Worker,
    queue: :orchestration,
    max_attempts: 20,
    unique: [keys: [:application_id, :lock_version, :to], period: :infinity]

  alias Fides.Orchestration.Orchestrator

  @doc "Schedules a move of the application, at its current version, `seconds` from now."
  @spec schedule(struct(), atom(), non_neg_integer()) :: :ok | {:error, term()}
  def schedule(application, to, seconds) do
    %{
      application_id: application.id,
      country_code: application.country_code,
      lock_version: application.lock_version,
      to: to
    }
    |> new(schedule_in: seconds)
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"application_id" => id, "lock_version" => version, "to" => to}}) do
    with {:ok, %{lock_version: ^version} = application} <- Orchestrator.application(id),
         {:ok, _moved} <-
           Orchestrator.move(application, String.to_existing_atom(to), "retry, back to #{to}") do
      :ok
    else
      {:ok, _changed} -> {:cancel, :superseded}
      {:error, :superseded} -> {:cancel, :superseded}
      {:error, :not_found} -> {:cancel, :not_found}
      {:error, error} -> {:error, error}
    end
  end
end
