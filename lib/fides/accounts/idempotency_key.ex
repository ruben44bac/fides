defmodule Fides.Accounts.IdempotencyKey do
  @moduledoc """
  A key a staff user sent with a command, with a hash of the request it came with and
  the response it got. The same key and request get that response again instead of a
  second effect; the same key with another request is refused. Keys expire after a
  day.

  Not audited: a key records a request, not a change to anyone's data.
  """

  use Fides.Platform.Resource, domain: Fides.Accounts

  postgres do
    table "idempotency_keys"
    repo Fides.Platform.Repo
  end

  audit do
    capture? false
  end

  actions do
    defaults [:read]

    create :reserve do
      description "Takes a key for a request before running it. Fails if the key is taken."
      accept [:actor_id, :key, :request_hash]
      change set_attribute(:expires_at, &__MODULE__.expiry/0)
    end

    update :complete do
      description "Keeps the response the request got."
      accept [:response_status, :response_body]
    end

    destroy :release do
      description "Frees a key whose request failed on the server, or that expired."
    end
  end

  policies do
    policy always() do
      authorize_if Fides.Platform.Checks.SystemActor
    end
  end

  attributes do
    attribute :actor_id, :uuid do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :key, :string do
      primary_key? true
      allow_nil? false
      public? true
      constraints max_length: 255
    end

    attribute :request_hash, :binary do
      description "SHA-256 of the method, path and body of the first request."
      allow_nil? false
      public? true
    end

    attribute :response_status, :integer do
      description "Nil while the first request runs."
      public? true
    end

    attribute :response_body, :map do
      public? true
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
  end

  classification do
    attribute :actor_id, :pseudonymous
    attribute :key, :internal
    attribute :request_hash, :pseudonymous
    attribute :response_status, :public
    attribute :response_body, :internal
    attribute :expires_at, :public
    attribute :inserted_at, :public
  end

  @doc false
  def expiry, do: DateTime.add(DateTime.utc_now(), 1, :day)
end
