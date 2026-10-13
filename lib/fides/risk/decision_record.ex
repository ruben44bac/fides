defmodule Fides.Risk.DecisionRecord do
  @moduledoc """
  One decision of the risk engine on an application: the revision it evaluated, the
  policy version and the bank profile it used, the canonical inputs with their hash,
  what each rule said, the outcome with its reason codes, the engine's code and the
  hash of the whole decision. With all of that, the decision can be computed again
  later and compared.

  A reevaluation records a new decision that points at the one it replaces; records
  are never changed or deleted.
  """

  use Fides.Platform.Resource, domain: Fides.Risk

  alias Fides.Platform.Checks.Agent
  alias Fides.Platform.Checks.GlobalRole
  alias Fides.Platform.Checks.ScopedRole
  alias Fides.Platform.Checks.SystemActor

  postgres do
    table "decision_records"
    repo Fides.Platform.Repo

    custom_indexes do
      index [:application_id, :inserted_at]
    end

    # The policy version is of the same country; the application, its revision and
    # the profile belong to other contexts
    custom_statements do
      statement :foreign_keys do
        up """
        ALTER TABLE decision_records
          ADD CONSTRAINT decision_records_policy_version_fkey
            FOREIGN KEY (country_code, policy_version_id) REFERENCES policy_versions (country_code, id),
          ADD CONSTRAINT decision_records_application_fkey
            FOREIGN KEY (country_code, application_id) REFERENCES credit_applications (country_code, id),
          ADD CONSTRAINT decision_records_revision_fkey
            FOREIGN KEY (country_code, revision_id) REFERENCES application_revisions (country_code, id),
          ADD CONSTRAINT decision_records_bank_profile_fkey
            FOREIGN KEY (country_code, bank_profile_id) REFERENCES bank_profiles (country_code, id),
          ADD CONSTRAINT decision_records_replaces_fkey
            FOREIGN KEY (country_code, replaces_id) REFERENCES decision_records (country_code, id)
        """

        down """
        ALTER TABLE decision_records
          DROP CONSTRAINT decision_records_replaces_fkey,
          DROP CONSTRAINT decision_records_bank_profile_fkey,
          DROP CONSTRAINT decision_records_revision_fkey,
          DROP CONSTRAINT decision_records_application_fkey,
          DROP CONSTRAINT decision_records_policy_version_fkey
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
        :application_id,
        :revision_id,
        :policy_version_id,
        :bank_profile_id,
        :replaces_id,
        :cause,
        :inputs,
        :inputs_hash,
        :rule_results,
        :outcome,
        :reason_codes,
        :engine_sha,
        :hash
      ]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if SystemActor
      authorize_if {Agent, names: [:risk]}
      authorize_if {GlobalRole, roles: [:admin, :auditor]}
      authorize_if {ScopedRole, roles: [:analyst, :risk_manager]}
    end

    policy action(:record) do
      authorize_if SystemActor
      authorize_if {Agent, names: [:risk]}
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

    attribute :application_id, :uuid, allow_nil?: false, public?: true

    attribute :revision_id, :uuid do
      description "The revision of the application's terms that was evaluated."
      allow_nil? false
      public? true
    end

    attribute :policy_version_id, :uuid, allow_nil?: false, public?: true
    attribute :bank_profile_id, :uuid, allow_nil?: false, public?: true

    attribute :replaces_id, :uuid do
      description "The decision this one replaces, when the application was evaluated again."
      public? true
    end

    attribute :cause, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:evaluation, :reevaluation]
    end

    attribute :inputs, :map do
      description "The canonical inputs the engine decided on: financial and public data only."
      allow_nil? false
      public? true
    end

    attribute :inputs_hash, :binary do
      description "SHA-256 of the inputs and the policy's parameters."
      allow_nil? false
    end

    attribute :rule_results, {:array, :map} do
      description "What each rule said, with its reason codes."
      allow_nil? false
      public? true
    end

    attribute :outcome, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:approve, :review, :reject]
    end

    attribute :reason_codes, {:array, :atom}, allow_nil?: false, public?: true, default: []

    attribute :engine_sha, :string do
      description "The commit of the engine that decided."
      allow_nil? false
      public? true
    end

    attribute :hash, :binary do
      description "SHA-256 of the inputs, the parameters, the rule results and the outcome."
      allow_nil? false
    end

    create_timestamp :inserted_at
  end

  classification do
    attribute :id, :pseudonymous
    attribute :country_code, :public
    attribute :application_id, :pseudonymous
    attribute :revision_id, :pseudonymous
    attribute :policy_version_id, :pseudonymous
    attribute :bank_profile_id, :pseudonymous
    attribute :replaces_id, :pseudonymous
    attribute :cause, :public
    attribute :inputs, :financial
    attribute :inputs_hash, :internal
    attribute :rule_results, :internal
    attribute :outcome, :public
    attribute :reason_codes, :public
    attribute :engine_sha, :public
    attribute :hash, :internal
    attribute :inserted_at, :public
  end
end
