defmodule Fides.Notifications do
  @moduledoc """
  Notifications context: what leaves Fides, signed and without personal data, to the
  systems that subscribed and to the applicant, and what comes in from providers,
  verified and never applied twice.
  """

  use Fides.Platform.Domain,
    boundary: [
      deps: [Fides.Platform, Fides.Origination, Fides.Identity, Fides.Countries],
      exports: [Signature, Seeds]
    ]

  resources do
    resource Fides.Notifications.InboundEvent do
      define :receive_event, action: :receive
      define :mark_event_processed, action: :process, args: [:result]
      define :list_inbound_events, action: :read
      define :get_inbound_event, action: :read, get_by: [:id]
    end

    resource Fides.Notifications.WebhookEndpoint do
      define :register_endpoint, action: :register
      define :disable_endpoint, action: :disable
      define :list_endpoints, action: :read
      define :subscribed_endpoints, action: :subscribed, args: [:event, :country_code]
    end

    resource Fides.Notifications.WebhookDelivery do
      define :announce_delivery, action: :announce
      define :record_delivery_attempt, action: :attempted, args: [:outcome, :http_status]
      define :mark_delivery_pending, action: :resend
      define :list_deliveries, action: :read
      define :get_delivery, action: :read, get_by: [:id]
    end

    resource Fides.Notifications.Notification do
      define :schedule_notification, action: :schedule
      define :mark_notification_sent, action: :sent
      define :mark_notification_failed, action: :failed
      define :list_notifications, action: :read
      define :get_notification, action: :read, get_by: [:id]
    end
  end

  @doc """
  Announces that an application entered `event`: one delivery, signed, to each
  receiver subscribed to the event in the application's country. Announcing the same
  change again adds nothing.
  """
  defdelegate announce(application, event, reason_codes, actor),
    to: Fides.Notifications.Announce,
    as: :run

  @doc "Schedules the applicant's notice about a change, in the language of their country."
  defdelegate notify(application, template, actor), to: Fides.Notifications.Notify, as: :schedule

  @doc "The language of a country's notices, from its locale."
  defdelegate language(country), to: Fides.Notifications.Templates

  @doc "The deliveries of a country that failed every attempt, the latest first."
  @spec failed_deliveries(String.t(), term()) :: {:ok, [struct()]} | {:error, term()}
  def failed_deliveries(country, actor) do
    require Ash.Query

    Fides.Notifications.WebhookDelivery
    |> Ash.Query.filter(state == :failed)
    |> Ash.Query.sort(attempted_at: :desc)
    |> Ash.read(tenant: country, actor: actor)
  end

  @doc """
  Sends a failed delivery to its receiver again: back to pending, with a new job that
  starts its attempts over.
  """
  @spec resend_delivery(struct(), term()) :: {:ok, struct()} | {:error, term()}
  def resend_delivery(delivery, actor) do
    with {:ok, pending} <-
           mark_delivery_pending(delivery, tenant: delivery.country_code, actor: actor),
         :ok <- Fides.Notifications.Deliver.enqueue(pending) do
      {:ok, pending}
    end
  end
end
