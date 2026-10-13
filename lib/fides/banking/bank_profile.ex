defmodule Fides.Banking.BankProfile do
  @moduledoc """
  A holder's bank data as a provider reported it for an application, in Fides' own
  terms: monthly income and total debt in minor units, recent months with income out of
  the last six, the provider's score from 0 to 1000, and the account reduced to its
  last four characters. The provider's answer itself is never kept, only its hash.

  A profile comes from a provider of the application's country and is never changed:
  fetching again makes a new profile.
  """

  use Fides.Platform.Resource,
    domain: Fides.Banking

  alias Fides.Platform.Checks.Agent
  alias Fides.Platform.Checks.GlobalRole
  alias Fides.Platform.Checks.ScopedRole
  alias Fides.Platform.Checks.SystemActor

  postgres do
    table "bank_profiles"
    repo Fides.Platform.Repo

    custom_indexes do
      index [:application_id, :inserted_at]
    end

    # The provider and the exchange are of the same country; the application belongs
    # to another context
    custom_statements do
      statement :foreign_keys do
        up """
        ALTER TABLE bank_profiles
          ADD CONSTRAINT bank_profiles_provider_fkey
            FOREIGN KEY (country_code, provider_id) REFERENCES bank_providers (country_code, id),
          ADD CONSTRAINT bank_profiles_exchange_fkey
            FOREIGN KEY (country_code, exchange_id) REFERENCES provider_exchanges (country_code, id),
          ADD CONSTRAINT bank_profiles_application_fkey
            FOREIGN KEY (country_code, application_id) REFERENCES credit_applications (country_code, id)
        """

        down """
        ALTER TABLE bank_profiles
          DROP CONSTRAINT bank_profiles_application_fkey,
          DROP CONSTRAINT bank_profiles_exchange_fkey,
          DROP CONSTRAINT bank_profiles_provider_fkey
        """
      end
    end
  end

  audit do
    append_only? true
  end

  actions do
    defaults [:read]

    create :record do
      accept [
        :provider_id,
        :application_id,
        :exchange_id,
        :observed_income_minor,
        :total_debt_minor,
        :income_months,
        :score,
        :account_masked,
        :origin,
        :payload_hash
      ]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if SystemActor
      authorize_if {Agent, names: [:banking, :risk]}
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
    attribute :exchange_id, :uuid, allow_nil?: false, public?: true

    attribute :observed_income_minor, :integer do
      allow_nil? false
      public? true
      constraints min: 0
    end

    attribute :total_debt_minor, :integer do
      allow_nil? false
      public? true
      constraints min: 0
    end

    attribute :income_months, :integer do
      allow_nil? false
      public? true
      constraints min: 0, max: 6
    end

    attribute :score, :integer do
      allow_nil? false
      public? true
      constraints min: 0, max: 1000
    end

    attribute :account_masked, :string, allow_nil?: false, public?: true

    attribute :origin, :atom do
      description "Whether the profile came from the provider or from a cached answer."
      allow_nil? false
      public? true
      default :live
      constraints one_of: [:live, :cache]
    end

    attribute :payload_hash, :binary do
      description "SHA-256 of the provider's answer."
      allow_nil? false
    end

    create_timestamp :inserted_at
  end

  classification do
    attribute :id, :pseudonymous
    attribute :country_code, :public
    attribute :provider_id, :pseudonymous
    attribute :application_id, :pseudonymous
    attribute :exchange_id, :pseudonymous
    attribute :observed_income_minor, :financial
    attribute :total_debt_minor, :financial
    attribute :income_months, :financial
    attribute :score, :financial
    attribute :account_masked, :financial
    attribute :origin, :public
    attribute :payload_hash, :internal
    attribute :inserted_at, :public
  end
end
