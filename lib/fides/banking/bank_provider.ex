defmodule Fides.Banking.BankProvider do
  @moduledoc """
  The bank data provider of a country. A synchronous provider answers the request
  directly; an asynchronous one accepts it and delivers the profile later through a
  signed webhook. `adapter` names the module that speaks the provider's format.
  """

  use Fides.Platform.Resource,
    domain: Fides.Banking

  postgres do
    table "bank_providers"
    repo Fides.Platform.Repo
  end

  actions do
    defaults [:read]

    create :seed do
      description "Creates a provider from the catalog, or updates it if it exists."
      accept [:name, :mode, :adapter, :status]
      upsert? true
      upsert_identity :unique_name
      upsert_fields [:mode, :adapter, :status]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action(:seed) do
      authorize_if Fides.Platform.Checks.SystemActor
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

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :mode, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:sync, :async]
    end

    attribute :adapter, :string do
      allow_nil? false
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
    attribute :country_code, :public
    attribute :name, :public
    attribute :mode, :public
    attribute :adapter, :public
    attribute :status, :public
    attribute :inserted_at, :public
    attribute :updated_at, :public
  end

  identities do
    identity :unique_name, [:name]
  end
end
