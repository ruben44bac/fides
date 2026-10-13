defmodule Fides.Banking.ProviderExchange do
  @moduledoc """
  One call to a country's bank provider: for which application, with which request
  id, and what came of it. Only hashes of what went and what came back are kept, never
  the bodies; the request's hash covers the document through its keyed hash. A retried
  call reuses its request id, so the provider can answer the same, and counts as the
  next attempt. Calls are never changed or deleted.

  The status is `ok` when the provider answered with a profile, `pending` when it
  accepted the request to answer later, `error` when it failed or answered something
  malformed, and `timeout` when it did not answer in time.
  """

  use Fides.Platform.Resource,
    domain: Fides.Banking

  alias Fides.Platform.Checks.Agent
  alias Fides.Platform.Checks.GlobalRole
  alias Fides.Platform.Checks.ScopedRole
  alias Fides.Platform.Checks.SystemActor

  postgres do
    table "provider_exchanges"
    repo Fides.Platform.Repo

    custom_indexes do
      index [:application_id, :request_id]
    end

    # The provider is of the same country; the application belongs to another context
    custom_statements do
      statement :foreign_keys do
        up """
        ALTER TABLE provider_exchanges
          ADD CONSTRAINT provider_exchanges_provider_fkey
            FOREIGN KEY (country_code, provider_id) REFERENCES bank_providers (country_code, id),
          ADD CONSTRAINT provider_exchanges_application_fkey
            FOREIGN KEY (country_code, application_id) REFERENCES credit_applications (country_code, id)
        """

        down """
        ALTER TABLE provider_exchanges
          DROP CONSTRAINT provider_exchanges_application_fkey,
          DROP CONSTRAINT provider_exchanges_provider_fkey
        """
      end
    end
  end

  # A record of calls, itself the evidence
  audit do
    capture? false
    append_only? true
  end

  actions do
    defaults [:read]

    create :record do
      accept [
        :provider_id,
        :application_id,
        :request_id,
        :request_hash,
        :response_hash,
        :status,
        :http_status,
        :error,
        :latency_ms,
        :attempt
      ]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if SystemActor
      authorize_if {Agent, names: [:banking]}
      authorize_if {GlobalRole, roles: [:admin, :auditor]}
      authorize_if {ScopedRole, roles: [:analyst, :risk_manager]}
    end

    policy action(:record) do
      authorize_if SystemActor
      authorize_if {Agent, names: [:banking]}
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

    attribute :provider_id, :uuid, allow_nil?: false, public?: true
    attribute :application_id, :uuid, allow_nil?: false, public?: true

    attribute :request_id, :string do
      description "The idempotency key sent to the provider; a retry of the same call reuses it."
      allow_nil? false
      public? true
      constraints max_length: 100
    end

    attribute :request_hash, :binary do
      description "SHA-256 of the request id, the provider and the document's keyed hash."
      allow_nil? false
    end

    attribute :response_hash, :binary do
      description "SHA-256 of the provider's answer, when there was one."
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:ok, :pending, :error, :timeout]
    end

    attribute :http_status, :integer, public?: true
    attribute :error, :string, public?: true
    attribute :latency_ms, :integer, allow_nil?: false, public?: true

    attribute :attempt, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    create_timestamp :inserted_at
  end

  classification do
    attribute :id, :pseudonymous
    attribute :country_code, :public
    attribute :provider_id, :pseudonymous
    attribute :application_id, :pseudonymous
    attribute :request_id, :pseudonymous
    attribute :request_hash, :internal
    attribute :response_hash, :internal
    attribute :status, :public
    attribute :http_status, :public
    attribute :error, :internal
    attribute :latency_ms, :internal
    attribute :attempt, :internal
    attribute :inserted_at, :public
  end
end
