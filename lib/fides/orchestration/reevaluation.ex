defmodule Fides.Orchestration.Reevaluation do
  @moduledoc """
  Sends the applications waiting for review under an older policy version back to the
  evaluation, once a new version is in force in their country. The database enqueues
  it when the version is published, in the same transaction. Each application goes
  back with the cause recorded, and its own step then runs the Risk agent, which
  records a decision that replaces the previous one.

  It runs in a queue of its own, and an application that moved in the meantime is
  left alone.
  """

  use Oban.Worker, queue: :reevaluation, max_attempts: 5

  require Logger

  alias Fides.Origination
  alias Fides.Platform.AuditContext
  alias Fides.Platform.SystemActor

  @actor SystemActor.new(:reevaluation)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"country_code" => country, "policy_version_id" => version_id}}) do
    with {:ok, version} <-
           Fides.Risk.get_policy_version(version_id, tenant: country, actor: @actor),
         {:ok, waiting} <-
           Origination.waiting_under_another_version(country, version.id, @actor) do
      cause = "policy version #{version.version} published"

      AuditContext.run([actor: SystemActor.audit_id(@actor), reason: cause], fn ->
        Enum.each(waiting, &send_back(&1, cause))
      end)

      :ok
    end
  end

  defp send_back(application, cause) do
    case Origination.reevaluate_application(application, cause, application.lock_version,
           tenant: application.country_code,
           actor: @actor
         ) do
      {:ok, _moved} ->
        :ok

      {:error, error} ->
        Logger.info(
          "application #{application.id} was not reevaluated: #{Exception.message(error)}"
        )
    end
  end
end
