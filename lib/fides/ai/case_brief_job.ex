defmodule Fides.AI.CaseBriefJob do
  @moduledoc """
  Writes the brief of an application that entered review, in the AI's own queue and
  with the AI's own identity, which sees no personal data and may move nothing. The
  life cycle declares the capability on entering review; the orchestrator's step
  enqueues this job for it, once per version of the application.
  """

  use Oban.Worker,
    queue: :ai,
    max_attempts: 3,
    unique: [keys: [:application_id, :lock_version], period: :infinity]

  alias Fides.Platform.AgentActor
  alias Fides.Platform.AuditContext

  @actor AgentActor.new(:ai)

  @doc "Enqueues the brief of the application at its current version."
  @spec enqueue(struct()) :: :ok | {:error, term()}
  def enqueue(application) do
    %{
      application_id: application.id,
      country_code: application.country_code,
      lock_version: application.lock_version
    }
    |> new()
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"application_id" => id, "country_code" => country}}) do
    with {:ok, application} <-
           Fides.Origination.get_application(id, tenant: country, actor: @actor),
         {:ok, _run} <-
           AuditContext.run([actor: AgentActor.audit_id(@actor), reason: "case brief"], fn ->
             Fides.AI.brief(application, @actor)
           end) do
      :ok
    end
  end
end
