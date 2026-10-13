defmodule Fides.Origination.ApplicationRevision do
  @moduledoc """
  A version of an application's terms: the amount and income declared, numbered from
  1 without gaps. A correction adds a revision instead of editing one, so every
  decision keeps pointing at what it evaluated. The database refuses to change or
  delete a revision.
  """

  use Fides.Platform.Resource, domain: Fides.Origination

  alias Fides.Platform.Checks.GlobalRole
  alias Fides.Platform.Checks.ScopedRole
  alias Fides.Platform.Checks.SystemActor

  postgres do
    table "application_revisions"
    repo Fides.Platform.Repo

    references do
      reference :application, match_with: [country_code: :country_code], match_type: :full
    end
  end

  audit do
    append_only? true
  end

  actions do
    defaults [:read]

    # Only through the application's commands, in their transaction
    create :add do
      description "Adds the next revision of an application's terms."
      accept [:application_id, :number, :amount_minor, :monthly_income_minor, :cause]
      change set_attribute(:submitted_at, &DateTime.utc_now/0)
      change Fides.Origination.ApplicationRevision.Changes.HashContent
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if SystemActor
      authorize_if {Fides.Platform.Checks.Agent, names: [:risk]}
      authorize_if {GlobalRole, roles: [:admin, :auditor]}
      authorize_if {ScopedRole, roles: [:analyst, :risk_manager]}
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

    attribute :application_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :number, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :amount_minor, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :monthly_income_minor, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :cause, :atom do
      description "submitted for the first revision, info_response for the answers."
      allow_nil? false
      public? true
      constraints one_of: [:submitted, :info_response]
    end

    attribute :content_hash, :binary do
      description "SHA-256 of the declared terms."
      allow_nil? false
      public? true
    end

    attribute :submitted_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
  end

  classification do
    attribute :id, :pseudonymous
    attribute :country_code, :public
    attribute :application_id, :pseudonymous
    attribute :number, :public
    attribute :amount_minor, :financial
    attribute :monthly_income_minor, :financial
    attribute :cause, :public
    attribute :content_hash, :pseudonymous
    attribute :submitted_at, :public
    attribute :inserted_at, :public
  end

  relationships do
    belongs_to :application, Fides.Origination.CreditApplication do
      source_attribute :application_id
      define_attribute? false
    end
  end

  identities do
    identity :unique_number, [:application_id, :number]
  end
end
