defmodule Fides.Notifications.InboundEvent do
  @moduledoc """
  An event a provider delivered to Fides, whether or not its signature was valid: the
  provider, the event's id and sequence, the request it answers, the hash of its body,
  and what became of it once processed. An event with a valid signature is received
  once per provider: a repeated delivery is answered, not recorded again, so it never
  applies twice. An event whose signature is invalid is kept as evidence and does not
  stop the genuine one from arriving later.
  """

  use Fides.Platform.Resource,
    domain: Fides.Notifications

  alias Fides.Platform.Checks.GlobalRole
  alias Fides.Platform.Checks.ScopedRole
  alias Fides.Platform.Checks.SystemActor

  postgres do
    table "inbound_events"
    repo Fides.Platform.Repo

    identity_wheres_to_sql unique_valid_event: "signature_valid"
  end

  # A record of what arrived, itself the evidence
  audit do
    capture? false
    immutable [:provider, :event_id, :signature_valid, :sequence, :request_id, :payload_hash]
  end

  actions do
    defaults [:read]

    create :receive do
      accept [:provider, :event_id, :signature_valid, :sequence, :request_id, :payload_hash]
    end

    update :process do
      accept []

      argument :result, :atom,
        allow_nil?: false,
        constraints: [one_of: [:applied, :ignored, :rejected]]

      change set_attribute(:result, arg(:result))
      change set_attribute(:processed_at, &DateTime.utc_now/0)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if SystemActor
      authorize_if {GlobalRole, roles: [:admin, :auditor]}
      authorize_if {ScopedRole, roles: [:analyst, :risk_manager]}
    end

    policy action([:receive, :process]) do
      authorize_if SystemActor
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

    attribute :provider, :string do
      description "The adapter key of the provider that delivered the event."
      allow_nil? false
      public? true
      constraints max_length: 50
    end

    attribute :event_id, :string do
      allow_nil? false
      public? true
      constraints max_length: 100
    end

    attribute :signature_valid, :boolean, allow_nil?: false, public?: true
    attribute :sequence, :integer, public?: true

    attribute :request_id, :string do
      description "The request of Fides the event answers."
      public? true
      constraints max_length: 100
    end

    attribute :payload_hash, :binary do
      description "SHA-256 of the body as delivered."
      allow_nil? false
    end

    attribute :result, :atom do
      description "What became of the event: applied, ignored because the application had moved on, or rejected as malformed."
      public? true
      constraints one_of: [:applied, :ignored, :rejected]
    end

    attribute :processed_at, :utc_datetime_usec, public?: true
    create_timestamp :received_at
  end

  classification do
    attribute :id, :pseudonymous
    attribute :country_code, :public
    attribute :provider, :public
    attribute :event_id, :pseudonymous
    attribute :signature_valid, :public
    attribute :sequence, :public
    attribute :request_id, :pseudonymous
    attribute :payload_hash, :internal
    attribute :result, :public
    attribute :processed_at, :public
    attribute :received_at, :public
  end

  identities do
    identity :unique_valid_event, [:provider, :event_id],
      where: expr(signature_valid == true),
      message: "was already received"
  end
end
