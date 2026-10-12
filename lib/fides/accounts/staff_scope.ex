defmodule Fides.Accounts.StaffScope do
  @moduledoc """
  A staff user's access to one country, with one role. Revoking keeps the row and
  granting again reuses it, so the history of a scope lives in the audit trail.
  """

  use Fides.Platform.Resource, domain: Fides.Accounts

  alias Fides.Platform.Checks.GlobalRole
  alias Fides.Platform.Checks.ScopedRole

  postgres do
    table "staff_scopes"
    repo Fides.Platform.Repo
  end

  audit do
    immutable [:user_id]
  end

  actions do
    defaults [:read]

    read :all_countries do
      description "Scopes, revoked ones included: in every country, or in the tenant's if one is given."
      multitenancy :allow_global
    end

    read :active_for_actor do
      description """
      Scopes not revoked, in every country, whatever the request's tenant. Only loaded
      through a staff user's active scopes.
      """

      multitenancy :bypass
      filter expr(is_nil(revoked_at))
    end

    create :grant do
      description "Gives a staff user a role in the tenant's country, or restores their revoked scope there."
      accept [:user_id, :role]
      upsert? true
      upsert_fields [:role, :granted_by, :revoked_at, :revoked_by]

      # After the policy, so a caller who may not grant learns nothing about the grantee
      validate Fides.Accounts.StaffScope.Validations.NoGlobalRole, before_action?: true
      change set_attribute(:granted_by, actor(:id))
      # An upsert only writes what the changeset sets: without these, a scope granted
      # again would stay revoked
      change set_attribute(:revoked_at, nil)
      change set_attribute(:revoked_by, nil)
    end

    update :revoke do
      description "Takes the scope away from the next request on. The row stays."
      accept []
      validate Fides.Accounts.StaffScope.Validations.NotRevoked
      change atomic_update(:revoked_at, expr(now()))
      change set_attribute(:revoked_by, actor(:id))
    end
  end

  policies do
    bypass action(:active_for_actor) do
      authorize_if accessing_from(Fides.Accounts.StaffUser, :active_scopes)
    end

    policy action(:all_countries) do
      access_type :strict
      authorize_if {GlobalRole, roles: [:admin, :auditor]}
    end

    policy action(:read) do
      authorize_if {GlobalRole, roles: [:admin, :auditor]}
      authorize_if {ScopedRole, roles: [:analyst, :risk_manager]}
    end

    policy action([:grant, :revoke]) do
      authorize_if {GlobalRole, roles: [:admin]}
    end
  end

  multitenancy do
    strategy :attribute
    attribute :country_code
  end

  attributes do
    # First, so the primary key is (user_id, country_code)
    attribute :user_id, :uuid do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :country_code, Fides.Platform.Types.CountryCode do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :role, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:analyst, :risk_manager]
    end

    attribute :granted_by, :uuid do
      allow_nil? false
      public? true
    end

    attribute :revoked_at, :utc_datetime_usec do
      public? true
    end

    attribute :revoked_by, :uuid do
      public? true
    end

    timestamps()
  end

  classification do
    attribute :user_id, :pseudonymous
    attribute :country_code, :public
    attribute :role, :public
    attribute :granted_by, :pseudonymous
    attribute :revoked_at, :public
    attribute :revoked_by, :pseudonymous
    attribute :inserted_at, :public
    attribute :updated_at, :public
  end

  relationships do
    belongs_to :user, Fides.Accounts.StaffUser do
      source_attribute :user_id
      define_attribute? false
    end

    belongs_to :granter, Fides.Accounts.StaffUser do
      source_attribute :granted_by
      define_attribute? false
    end

    belongs_to :revoker, Fides.Accounts.StaffUser do
      source_attribute :revoked_by
      define_attribute? false
    end
  end
end
