defmodule Fides.Identity.Person do
  @moduledoc """
  The holder of a credit: one per document and country, whether or not they ever use
  the portal.

  The name, the document and the contact email are encrypted. Fides finds a holder by
  keyed hashes of the document and of the email, never by the values themselves. The
  birth date and the sex only serve to check documents that encode them, so they are
  not stored.
  """

  use Fides.Platform.Resource,
    domain: Fides.Identity,
    extensions: [AshCloak]

  postgres do
    table "people"
    repo Fides.Platform.Repo

    references do
      reference :document_kind, match_with: [country_code: :country_code], match_type: :full
    end
  end

  cloak do
    vault Fides.Platform.Vault
    attributes [:name, :document, :email]
  end

  actions do
    defaults [:read]

    create :resolve do
      description """
      Finds the holder of a document in the tenant's country, or creates them. The
      document must be valid for the country and match the holder's data.
      """

      accept []
      upsert? true
      upsert_identity :unique_document
      upsert_fields []

      argument :document_type, :string, allow_nil?: false
      argument :document, :string, allow_nil?: false, sensitive?: true
      argument :given_names, :string, allow_nil?: false, sensitive?: true
      argument :first_surname, :string, allow_nil?: false, sensitive?: true
      argument :second_surname, :string, sensitive?: true
      argument :email, :string, allow_nil?: false, sensitive?: true
      argument :birth_date, :date, sensitive?: true

      argument :sex, :atom do
        sensitive? true
        constraints one_of: [:female, :male]
      end

      change Fides.Identity.Person.Changes.Resolve
    end
  end

  policies do
    policy action_type([:read, :create]) do
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

    attribute :document_type, :string do
      allow_nil? false
      public? true
    end

    attribute :document_hash, :binary do
      description "Keyed hash of the document: finds the holder without decrypting anything."
      allow_nil? false
    end

    attribute :name, :map do
      allow_nil? false

      constraints fields: [
                    given_names: [type: :string, allow_nil?: false],
                    first_surname: [type: :string, allow_nil?: false],
                    second_surname: [type: :string]
                  ]
    end

    attribute :document, :string, allow_nil?: false
    attribute :email, :string, allow_nil?: false

    attribute :email_hash, :binary do
      description "Keyed hash of the contact email, to link a portal user with their holder."
      allow_nil? false
    end

    attribute :adult_verified_at, :utc_datetime_usec do
      description "When an adult birth date encoded in the document was verified."
      public? true
    end

    timestamps()
  end

  classification do
    attribute :id, :pseudonymous
    attribute :country_code, :public
    attribute :document_type, :public
    attribute :document_hash, :pseudonymous
    attribute :name, :pii
    attribute :document, :pii
    attribute :email, :pii
    attribute :email_hash, :pseudonymous
    attribute :adult_verified_at, :public
    attribute :inserted_at, :public
    attribute :updated_at, :public
  end

  relationships do
    belongs_to :document_kind, Fides.Identity.DocumentType do
      source_attribute :document_type
      destination_attribute :code
      define_attribute? false
      attribute_type :string
    end
  end

  identities do
    identity :unique_document, [:document_hash]
  end
end
