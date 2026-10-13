defmodule Fides.Notifications.Notification do
  @moduledoc """
  A notice to an applicant about their application: which template, in which
  language, through which channel, and whether it was sent. The notice keeps no
  address: the mail asks Identity for the recipient when it is sent.
  """

  use Fides.Platform.Resource, domain: Fides.Notifications

  alias Fides.Platform.Checks.Agent
  alias Fides.Platform.Checks.GlobalRole
  alias Fides.Platform.Checks.ScopedRole
  alias Fides.Platform.Checks.SystemActor

  postgres do
    table "notifications"
    repo Fides.Platform.Repo

    custom_indexes do
      index [:application_id, :inserted_at]
    end
  end

  audit do
    capture? false
    immutable [:application_id, :person_id, :lock_version, :template, :language, :channel]
  end

  actions do
    defaults [:read]

    create :schedule do
      accept [:application_id, :person_id, :lock_version, :template, :language, :channel]
      upsert? true
      upsert_identity :once_per_change
      upsert_fields []
    end

    update :sent do
      accept []
      change set_attribute(:state, :sent)
      change set_attribute(:sent_at, &DateTime.utc_now/0)
    end

    update :failed do
      accept []
      change set_attribute(:state, :failed)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if SystemActor
      authorize_if {Agent, names: [:notifier]}
      authorize_if {GlobalRole, roles: [:admin, :auditor]}
      authorize_if {ScopedRole, roles: [:analyst, :risk_manager]}
    end

    policy action([:schedule, :sent, :failed]) do
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

    attribute :application_id, :uuid, allow_nil?: false, public?: true

    attribute :person_id, :uuid do
      description "The holder the notice is for; the mail asks Identity for their address."
      allow_nil? false
      public? true
    end

    attribute :lock_version, :integer do
      description "The version of the application whose change the notice is about."
      allow_nil? false
      public? true
    end

    attribute :template, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:info_requested, :approved, :rejected]
    end

    attribute :language, :string do
      allow_nil? false
      public? true
      constraints match: ~r/^[a-z]{2}$/
    end

    attribute :channel, :atom do
      allow_nil? false
      public? true
      default :email
      constraints one_of: [:email]
    end

    attribute :state, :atom do
      allow_nil? false
      public? true
      default :pending
      constraints one_of: [:pending, :sent, :failed]
    end

    attribute :sent_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  classification do
    attribute :id, :pseudonymous
    attribute :country_code, :public
    attribute :application_id, :pseudonymous
    attribute :person_id, :pseudonymous
    attribute :lock_version, :public
    attribute :template, :public
    attribute :language, :public
    attribute :channel, :public
    attribute :state, :public
    attribute :sent_at, :public
    attribute :inserted_at, :public
    attribute :updated_at, :public
  end

  identities do
    identity :once_per_change, [:application_id, :template, :lock_version]
  end
end
