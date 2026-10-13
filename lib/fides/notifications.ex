defmodule Fides.Notifications do
  @moduledoc """
  Notifications context: what leaves Fides signed, and what comes in from providers,
  verified and never applied twice.
  """

  use Fides.Platform.Domain,
    boundary: [deps: [Fides.Platform], exports: [Signature]]

  resources do
    resource Fides.Notifications.InboundEvent do
      define :receive_event, action: :receive
      define :mark_event_processed, action: :process, args: [:result]
      define :list_inbound_events, action: :read
      define :get_inbound_event, action: :read, get_by: [:id]
    end
  end
end
