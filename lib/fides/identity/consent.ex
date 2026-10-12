defmodule Fides.Identity.Consent do
  @moduledoc """
  A holder's consent to process their data for a purpose: which version of the text
  they accepted, through which channel and when. Consents are evidence, so the
  database refuses to change or delete them.
  """

  use Fides.Platform.Resource, domain: Fides.Identity

  postgres do
    table "consents"
    repo Fides.Platform.Repo

    references do
      reference :person, match_with: [country_code: :country_code], match_type: :full
    end
  end

  audit do
    append_only? true
  end

  actions do
    defaults [:read]

    create :accept do
      description "Records that a holder of the tenant's country accepted a version of a text."
      accept [:person_id, :purpose, :text_version, :channel]
      change set_attribute(:accepted_at, &DateTime.utc_now/0)
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

    attribute :person_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :purpose, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:credit_evaluation]
    end

    attribute :text_version, :string do
      description "The version of the text the holder was shown."
      allow_nil? false
      public? true
      constraints max_length: 64
    end

    attribute :channel, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:api, :form, :chat]
    end

    attribute :accepted_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
  end

  classification do
    attribute :id, :pseudonymous
    attribute :country_code, :public
    attribute :person_id, :pseudonymous
    attribute :purpose, :public
    attribute :text_version, :public
    attribute :channel, :public
    attribute :accepted_at, :public
    attribute :inserted_at, :public
  end

  relationships do
    belongs_to :person, Fides.Identity.Person do
      source_attribute :person_id
      define_attribute? false
    end
  end
end
