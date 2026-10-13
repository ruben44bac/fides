defmodule Fides.Notifications.WebhookDelivery do
  @moduledoc """
  One event on its way to one receiver: the event's id and type, the application and
  the hash of the body, how many attempts were made and how the last one went. A
  receiver gets each event once: the delivery is unique per receiver and event, and
  repeating the step that announced the event adds nothing.

  The state is `pending` until the receiver answers 2xx, then `delivered`; after the
  last attempt it is `failed`, to be sent again from the console.
  """

  use Fides.Platform.Resource, domain: Fides.Notifications

  alias Fides.Platform.Checks.Agent
  alias Fides.Platform.Checks.GlobalRole
  alias Fides.Platform.Checks.ScopedRole
  alias Fides.Platform.Checks.SystemActor

  postgres do
    table "webhook_deliveries"
    repo Fides.Platform.Repo

    references do
      reference :endpoint, on_delete: :restrict
    end

    custom_indexes do
      index [:application_id, :inserted_at]
    end
  end

  # A record of deliveries, itself the evidence
  audit do
    capture? false
    immutable [:endpoint_id, :event_id, :event_type, :application_id, :payload, :payload_hash]
  end

  actions do
    defaults [:read]

    create :announce do
      accept [:endpoint_id, :event_id, :event_type, :application_id, :payload, :payload_hash]
      upsert? true
      upsert_identity :once_per_receiver
      upsert_fields []
    end

    update :attempted do
      description "Records an attempt: delivered on a 2xx, failed after the last one, pending otherwise."
      accept []
      argument :http_status, :integer

      argument :outcome, :atom,
        allow_nil?: false,
        constraints: [one_of: [:delivered, :pending, :failed]]

      change set_attribute(:last_status, arg(:http_status))
      change set_attribute(:state, arg(:outcome))
      change atomic_update(:attempts, expr(attempts + 1))
      change set_attribute(:attempted_at, &DateTime.utc_now/0)
    end

    update :resend do
      description "Puts a failed delivery back to pending, for the console to send it again."
      accept []
      require_atomic? false
      change filter(expr(state == :failed))
      change set_attribute(:state, :pending)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if SystemActor
      authorize_if {Agent, names: [:notifier]}
      authorize_if {GlobalRole, roles: [:admin, :auditor]}
      authorize_if {ScopedRole, roles: [:analyst, :risk_manager]}
    end

    # Whoever works the console sends a failed delivery again
    policy action(:resend) do
      authorize_if {GlobalRole, roles: [:admin]}
      authorize_if {ScopedRole, roles: [:analyst]}
    end

    policy action([:announce, :attempted]) do
      authorize_if SystemActor
      authorize_if {Agent, names: [:notifier]}
    end
  end

  multitenancy do
    strategy :attribute
    attribute :country_code
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :country_code, Fides.Platform.Types.CountryCode do
      allow_nil? false
      public? true
    end

    attribute :event_id, :string do
      allow_nil? false
      public? true
      constraints max_length: 100
    end

    attribute :event_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: Fides.Origination.states()
    end

    attribute :application_id, :uuid, allow_nil?: false, public?: true

    attribute :payload, :map do
      description "The event as sent: ids, country, state and reason codes, never personal data."
      allow_nil? false
      public? true
    end

    attribute :payload_hash, :binary do
      description "SHA-256 of the body as signed."
      allow_nil? false
    end

    attribute :state, :atom do
      allow_nil? false
      public? true
      default :pending
      constraints one_of: [:pending, :delivered, :failed]
    end

    attribute :attempts, :integer, allow_nil?: false, public?: true, default: 0
    attribute :last_status, :integer, public?: true
    attribute :attempted_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  classification do
    attribute :id, :pseudonymous
    attribute :country_code, :public
    attribute :endpoint_id, :pseudonymous
    attribute :event_id, :pseudonymous
    attribute :event_type, :public
    attribute :application_id, :pseudonymous
    attribute :payload, :internal
    attribute :payload_hash, :internal
    attribute :state, :public
    attribute :attempts, :public
    attribute :last_status, :public
    attribute :attempted_at, :public
    attribute :inserted_at, :public
    attribute :updated_at, :public
  end

  relationships do
    belongs_to :endpoint, Fides.Notifications.WebhookEndpoint, allow_nil?: false, public?: true
  end

  identities do
    identity :once_per_receiver, [:endpoint_id, :event_id], message: "was already announced"
  end
end
