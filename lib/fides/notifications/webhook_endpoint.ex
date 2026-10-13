defmodule Fides.Notifications.WebhookEndpoint do
  @moduledoc """
  A system that receives Fides' events: its URL, the secret its deliveries are signed
  with, the event types it subscribed to and, when it only wants one country's
  events, that country. The secret is encrypted, and only a delivery decrypts it.
  Endpoints are global: an admin registers them.
  """

  use Fides.Platform.Resource,
    domain: Fides.Notifications,
    extensions: [AshCloak]

  alias Fides.Platform.Checks.Agent
  alias Fides.Platform.Checks.GlobalRole
  alias Fides.Platform.Checks.SystemActor

  postgres do
    table "webhook_endpoints"
    repo Fides.Platform.Repo
  end

  audit do
    filtered [:encrypted_secret]
  end

  cloak do
    vault Fides.Platform.Vault
    attributes [:secret]
    on_decrypt {Fides.Notifications.WebhookEndpoint.DecryptGuard, :approve, []}
  end

  actions do
    defaults [:read]

    create :register do
      description "Registers a receiver, with the secret its deliveries are signed with."
      accept [:name, :url, :events, :country_filter]

      argument :secret, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [min_length: 16]

      change fn changeset, _context ->
        AshCloak.encrypt_and_set(
          changeset,
          :secret,
          Ash.Changeset.get_argument(changeset, :secret)
        )
      end
    end

    update :disable do
      description "Stops deliveries to the receiver."
      accept []
      change set_attribute(:status, :disabled)
    end

    read :subscribed do
      description "The active receivers of an event type in a country: subscribed to it, and to the country or to every one."
      argument :event, :atom, allow_nil?: false
      argument :country_code, Fides.Platform.Types.CountryCode, allow_nil?: false

      filter expr(
               status == :active and ^arg(:event) in events and
                 (is_nil(country_filter) or country_filter == ^arg(:country_code))
             )
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if SystemActor
      authorize_if {Agent, names: [:notifier]}
      authorize_if {GlobalRole, roles: [:admin, :auditor]}
    end

    policy action([:register, :disable]) do
      authorize_if SystemActor
      authorize_if {GlobalRole, roles: [:admin]}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints max_length: 100
    end

    attribute :url, :string do
      allow_nil? false
      public? true
      constraints max_length: 500, match: ~r{^https?://}
    end

    attribute :secret, :string, allow_nil?: false

    attribute :events, {:array, :atom} do
      description "The event types the receiver subscribed to: states an application enters."
      allow_nil? false
      public? true
      constraints items: [one_of: Fides.Origination.states()], min_length: 1
    end

    attribute :country_filter, Fides.Platform.Types.CountryCode do
      description "The only country whose events the receiver wants, or nil for every country."
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :active
      constraints one_of: [:active, :disabled]
    end

    timestamps()
  end

  classification do
    attribute :id, :pseudonymous
    attribute :name, :public
    attribute :url, :internal
    attribute :secret, :internal
    attribute :events, :public
    attribute :country_filter, :public
    attribute :status, :public
    attribute :inserted_at, :public
    attribute :updated_at, :public
  end

  identities do
    identity :unique_url, [:url], message: "is already registered"
  end
end
