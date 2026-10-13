defmodule Fides.Notifications do
  @moduledoc """
  Notifications context: what leaves Fides, signed and without personal data, to the
  systems that subscribed, and what comes in from providers, verified and never
  applied twice.
  """

  use Fides.Platform.Domain,
    boundary: [deps: [Fides.Platform, Fides.Origination], exports: [Signature]]

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
      define :list_deliveries, action: :read
      define :get_delivery, action: :read, get_by: [:id]
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
end
