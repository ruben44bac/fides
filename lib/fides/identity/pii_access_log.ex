defmodule Fides.Identity.PiiAccessLog do
  @moduledoc """
  One look at a holder's personal data by a member of staff: who revealed which field
  of whom, when, and for what reason. Nothing personal is revealed without its row,
  and rows are never changed or deleted.
  """

  use Fides.Platform.Resource, domain: Fides.Identity

  alias Fides.Platform.Checks.GlobalRole
  alias Fides.Platform.Checks.ScopedRole
  alias Fides.Platform.Checks.SystemActor

  postgres do
    table "pii_access_log"
    repo Fides.Platform.Repo

    custom_indexes do
      index [:subject_id, :accessed_at]
    end

    foreign_key_names [
      {:accessed_by, "pii_access_log_accessed_by_fkey", "is not a staff user"}
    ]

    # Staff belong to another context, so the reference is a plain column
    custom_statements do
      statement :staff_foreign_key do
        up """
        ALTER TABLE pii_access_log ADD CONSTRAINT pii_access_log_accessed_by_fkey
          FOREIGN KEY (accessed_by) REFERENCES staff_users (id)
        """

        down "ALTER TABLE pii_access_log DROP CONSTRAINT pii_access_log_accessed_by_fkey"
      end
    end
  end

  audit do
    append_only? true
  end

  actions do
    defaults [:read]

    create :record do
      description """
      Records that the actor reveals a field of a subject in the tenant's country, and
      why. The reason is required: without one, nothing is recorded or revealed.
      """

      accept [:subject_type, :subject_id, :field, :reason]
      change set_attribute(:accessed_by, actor(:id))
      change set_attribute(:accessed_at, &DateTime.utc_now/0)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if SystemActor
      authorize_if {GlobalRole, roles: [:admin, :auditor]}
      authorize_if {ScopedRole, roles: [:analyst, :risk_manager]}
    end

    # Only the staff who work a holder's country see their data
    policy action(:record) do
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

    attribute :subject_type, :atom do
      description "Whose data: a holder's, for now."
      allow_nil? false
      public? true
      constraints one_of: [:person]
    end

    attribute :subject_id, :uuid, allow_nil?: false, public?: true

    attribute :field, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:name, :document, :email]
    end

    attribute :accessed_by, :uuid do
      description "The staff user who revealed the field."
      allow_nil? false
      public? true
    end

    attribute :reason, :string do
      allow_nil? false
      public? true
      constraints max_length: 1000
    end

    attribute :accessed_at, :utc_datetime_usec, allow_nil?: false, public?: true

    create_timestamp :inserted_at
  end

  classification do
    attribute :id, :pseudonymous
    attribute :country_code, :public
    attribute :subject_type, :public
    attribute :subject_id, :pseudonymous
    attribute :field, :public
    attribute :accessed_by, :pseudonymous
    attribute :reason, :internal
    attribute :accessed_at, :public
    attribute :inserted_at, :public
  end
end
