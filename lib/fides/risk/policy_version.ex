defmodule Fides.Risk.PolicyVersion do
  @moduledoc """
  A version of a country's policy thresholds, numbered from 1 in each country.

  A risk manager proposes it as a draft, and another risk manager of the country
  puts it in force, which retires the version it replaces: a country has at most one
  version in force. The thresholds never change once proposed; correcting them means
  proposing another version. The database refuses a version approved by whoever
  proposed it, however it is written.
  """

  use Fides.Platform.Resource, domain: Fides.Risk

  alias Fides.Platform.Checks.GlobalRole
  alias Fides.Platform.Checks.ScopedRole
  alias Fides.Risk.PolicyVersion.Changes.NumberAndCheck
  alias Fides.Risk.PolicyVersion.Changes.RetireVersionInForce
  alias Fides.Risk.PolicyVersion.Validations.OtherThanProposer

  postgres do
    table "policy_versions"
    repo Fides.Platform.Repo

    identity_wheres_to_sql in_force: "status = 'published'"

    foreign_key_names [
      {:proposed_by, "policy_versions_proposed_by_fkey", "is not a staff user"},
      {:approved_by, "policy_versions_approved_by_fkey", "is not a staff user"}
    ]

    check_constraints do
      check_constraint :approved_by, "policy_versions_two_people",
        check: "approved_by <> proposed_by",
        message: "must be someone other than who proposed the version"

      check_constraint :approved_by, "policy_versions_approved_when_in_force",
        check: "status = 'draft' OR approved_by IS NOT NULL",
        message: "is required once the version is published"
    end

    # Staff belong to another context, so the references are plain columns
    custom_statements do
      statement :staff_foreign_keys do
        up """
        ALTER TABLE policy_versions
          ADD CONSTRAINT policy_versions_proposed_by_fkey FOREIGN KEY (proposed_by) REFERENCES staff_users (id),
          ADD CONSTRAINT policy_versions_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES staff_users (id)
        """

        down """
        ALTER TABLE policy_versions
          DROP CONSTRAINT policy_versions_approved_by_fkey,
          DROP CONSTRAINT policy_versions_proposed_by_fkey
        """
      end
    end
  end

  audit do
    immutable [:version, :params, :proposed_by]
  end

  actions do
    defaults [:read]

    read :in_force do
      description "The version in force in the tenant's country."
      get? true
      filter expr(status == :published)
    end

    create :propose do
      description "Proposes thresholds for the tenant's country as a draft, numbered after its last version."
      accept [:params]
      change set_attribute(:proposed_by, actor(:id))
      change NumberAndCheck
    end

    update :publish do
      description "Puts a draft in force and retires the version it replaces. Someone other than the proposer does it."
      accept []
      require_atomic? false

      # A version is put in force once, even by two approvers at the same time
      change filter(expr(status == :draft))
      validate OtherThanProposer
      change set_attribute(:status, :published)
      change set_attribute(:approved_by, actor(:id))
      change set_attribute(:effective_from, &DateTime.utc_now/0)
      change RetireVersionInForce
    end

    update :retire do
      description "Takes the version out of force when its successor is published."
      accept []
      change set_attribute(:status, :retired)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if {GlobalRole, roles: [:admin, :auditor]}
      authorize_if {ScopedRole, roles: [:analyst, :risk_manager]}
    end

    policy action([:propose, :publish]) do
      authorize_if {ScopedRole, roles: [:risk_manager]}
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

    attribute :version, :integer do
      description "Numbered from 1 in each country."
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :params, :map do
      description "The thresholds of the country's rules."
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      description "draft, then published while in force, then retired."
      allow_nil? false
      public? true
      default :draft
      constraints one_of: [:draft, :published, :retired]
    end

    attribute :proposed_by, :uuid do
      allow_nil? false
      public? true
    end

    attribute :approved_by, :uuid do
      public? true
    end

    attribute :effective_from, :utc_datetime_usec do
      description "When the version was put in force."
      public? true
    end

    timestamps()
  end

  classification do
    attribute :id, :pseudonymous
    attribute :country_code, :public
    attribute :version, :public
    attribute :params, :public
    attribute :status, :public
    attribute :proposed_by, :pseudonymous
    attribute :approved_by, :pseudonymous
    attribute :effective_from, :public
    attribute :inserted_at, :public
    attribute :updated_at, :public
  end

  identities do
    identity :unique_version, [:version]
    identity :in_force, [:status], where: expr(status == :published)
  end
end
