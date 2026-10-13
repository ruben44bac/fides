defmodule Fides.Notifications.Notify do
  @moduledoc """
  Sends the applicant their notice about a change, by its own job: scheduled once per
  change, sent in the language of the application's country, and marked sent or failed.
  """

  use Oban.Worker,
    queue: :notices,
    max_attempts: 5,
    unique: [keys: [:notification_id], period: :infinity]

  alias Fides.Notifications.Mail
  alias Fides.Notifications.Templates
  alias Fides.Platform.AgentActor

  @actor AgentActor.new(:notifier)

  @doc "Schedules the notice of a change, if not scheduled already."
  @spec schedule(struct(), atom(), term()) :: :ok | {:error, term()}
  def schedule(application, template, actor) do
    with {:ok, notification} <-
           Fides.Notifications.schedule_notification(
             %{
               application_id: application.id,
               person_id: application.person_id,
               lock_version: application.lock_version,
               template: template,
               language: Templates.language(application.country_code),
               channel: :email
             },
             tenant: application.country_code,
             actor: actor
           ),
         {:ok, _job} <-
           %{country_code: application.country_code, notification_id: notification.id}
           |> new()
           |> Oban.insert() do
      :ok
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"country_code" => country, "notification_id" => id}} = job) do
    opts = [tenant: country, actor: @actor]

    case Fides.Notifications.get_notification(id, opts) do
      {:ok, %{state: :pending} = notification} -> send_pending(notification, job, opts)
      {:ok, _already_handled} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp send_pending(notification, job, opts) do
    case Mail.send(notification) do
      {:ok, _sent} ->
        Fides.Notifications.mark_notification_sent!(notification, opts)
        :ok

      {:error, error} ->
        if job.attempt >= job.max_attempts,
          do: Fides.Notifications.mark_notification_failed!(notification, opts)

        {:error, error}
    end
  end
end
