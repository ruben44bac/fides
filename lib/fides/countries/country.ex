defmodule Fides.Countries.Country do
  @moduledoc "A country Fides operates in, with its currency, locale, timezone and data region."

  use Fides.Platform.Resource,
    domain: Fides.Countries

  postgres do
    table "countries"
    repo Fides.Platform.Repo

    # varchar rather than char: Ash compares IN-lists as text, and a char(n) column
    # cannot serve that comparison from its index.
    migration_types code: {:varchar, 2}, currency: {:varchar, 3}

    check_constraints do
      check_constraint :code, "countries_code_format",
        check: "code ~ '^[A-Z]{2}$'",
        message: "must be an ISO 3166-1 alpha-2 code"

      check_constraint :currency, "countries_currency_format",
        check: "currency ~ '^[A-Z]{3}$'",
        message: "must be an ISO 4217 code"

      check_constraint :code, "countries_code_immutable", message: "cannot change"
    end
  end

  audit do
    immutable [:code]
  end

  actions do
    defaults [:read]

    create :seed do
      description "Creates a country from the seed catalog, or updates it if it exists."
      accept [:code, :currency, :default_locale, :timezone, :data_region, :status]
      upsert? true
      upsert_fields [:currency, :default_locale, :timezone, :data_region, :status]
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

  attributes do
    attribute :code, :string do
      description "ISO 3166-1 alpha-2."
      primary_key? true
      allow_nil? false
      public? true
      constraints min_length: 2, max_length: 2
    end

    attribute :currency, :string do
      description "ISO 4217. Credit amounts in this country use it."
      allow_nil? false
      public? true
      constraints min_length: 3, max_length: 3
    end

    attribute :default_locale, :string do
      allow_nil? false
      public? true
    end

    attribute :timezone, :string do
      allow_nil? false
      public? true
    end

    attribute :data_region, :atom do
      description "Decides which AI models may process this country's data."
      allow_nil? false
      public? true
      constraints one_of: [:eu, :latam]
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :active
      constraints one_of: [:active, :pilot, :disabled]
    end

    timestamps()
  end

  classification do
    attribute :code, :public
    attribute :currency, :public
    attribute :default_locale, :public
    attribute :timezone, :public
    attribute :data_region, :public
    attribute :status, :public
    attribute :inserted_at, :public
    attribute :updated_at, :public
  end

  identities do
    # Target of the (country_code, currency) foreign key from credit applications.
    identity :code_currency, [:code, :currency]
  end
end
