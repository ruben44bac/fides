defmodule Fides.Identity.DocumentType do
  @moduledoc "An identity document a country accepts, such as the Spanish DNI or the Mexican CURP."

  use Fides.Platform.Resource,
    domain: Fides.Identity

  postgres do
    table "document_types"
    repo Fides.Platform.Repo
  end

  actions do
    defaults [:read]

    create :seed do
      description "Creates a document type from the catalog, or updates it if it exists."
      accept [:code, :active]
      upsert? true
      upsert_fields [:active]
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
    attribute :country_code, Fides.Platform.Types.CountryCode do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :code, :string do
      description "Short code of the document, such as DNI, NIE or CURP."
      primary_key? true
      allow_nil? false
      public? true
      constraints max_length: 10
    end

    attribute :active, :boolean do
      allow_nil? false
      public? true
      default true
    end

    timestamps()
  end

  classification do
    attribute :country_code, :public
    attribute :code, :public
    attribute :active, :public
    attribute :inserted_at, :public
    attribute :updated_at, :public
  end
end
