defmodule Fides.Origination.CreditApplication do
  @moduledoc """
  A credit application. Its state changes only through commands with an actor and,
  for people, a reason; never through an edit.

  Its amount and income are copies of its current revision, and revisions are
  append-only. A holder has at most one application that is not final, final states
  never change, and every change increments `lock_version`, which commands compare
  with the version they expect. A rejected or cancelled application can be retried
  once, as a new application of the same holder. The database enforces all of this
  as well.
  """

  use Fides.Platform.Resource,
    domain: Fides.Origination,
    extensions: [AshJsonApi.Resource]

  alias Fides.Origination.CreditApplication.Changes
  alias Fides.Origination.Lifecycle
  alias Fides.Platform.Checks.GlobalRole
  alias Fides.Platform.Checks.InScopedCountry
  alias Fides.Platform.Checks.ScopedRole
  alias Fides.Platform.Checks.SystemActor

  # Reads only: the commands are in Fides.Origination.ApplicationCommands
  json_api do
    type "application"

    routes do
      base "/applications"
      get :visible
      index :visible
    end
  end

  postgres do
    table "credit_applications"
    repo Fides.Platform.Repo

    identity_wheres_to_sql one_open_per_holder:
                             "state NOT IN ('approved', 'rejected', 'cancelled')"

    foreign_key_names [
      {:currency, "credit_applications_currency_fkey", "is not the currency of the country"},
      {:person_id, "credit_applications_person_fkey", "is not a holder of the country"},
      {:previous_application_id, "credit_applications_previous_fkey",
       "is not an application of the same holder"},
      {:policy_version_id, "credit_applications_policy_version_fkey",
       "is not a policy version of the country"}
    ]

    migration_types currency: {:varchar, 3}

    check_constraints do
      check_constraint :amount_minor, "credit_applications_amount_positive",
        check: "amount_minor > 0",
        message: "must be positive"

      check_constraint :monthly_income_minor, "credit_applications_income_positive",
        check: "monthly_income_minor > 0",
        message: "must be positive"

      check_constraint :state, "credit_applications_final_state", message: "is final"
    end

    custom_indexes do
      # The country's applications by state, newest first
      index ["state", "submitted_at DESC", "id"], name: "credit_applications_inbox_index"
    end

    # Holders and policy versions belong to other contexts, so their references are
    # plain columns with foreign keys that include the country
    custom_statements do
      statement :currency_foreign_key do
        up """
        ALTER TABLE credit_applications ADD CONSTRAINT credit_applications_currency_fkey
          FOREIGN KEY (country_code, currency) REFERENCES countries (code, currency)
        """

        down "ALTER TABLE credit_applications DROP CONSTRAINT credit_applications_currency_fkey"
      end

      statement :person_foreign_key do
        up """
        ALTER TABLE credit_applications ADD CONSTRAINT credit_applications_person_fkey
          FOREIGN KEY (person_id, country_code) REFERENCES people (id, country_code)
        """

        down "ALTER TABLE credit_applications DROP CONSTRAINT credit_applications_person_fkey"
      end

      statement :policy_version_foreign_key do
        up """
        ALTER TABLE credit_applications ADD CONSTRAINT credit_applications_policy_version_fkey
          FOREIGN KEY (policy_version_id, country_code) REFERENCES policy_versions (id, country_code)
        """

        down """
        ALTER TABLE credit_applications DROP CONSTRAINT credit_applications_policy_version_fkey
        """
      end

      # A retry points to an application of the same holder and country
      statement :holder_application_unique do
        up """
        CREATE UNIQUE INDEX credit_applications_holder_application_index
          ON credit_applications (id, person_id, country_code)
        """

        down "DROP INDEX credit_applications_holder_application_index"
      end

      statement :previous_application_foreign_key do
        up """
        ALTER TABLE credit_applications ADD CONSTRAINT credit_applications_previous_fkey
          FOREIGN KEY (previous_application_id, person_id, country_code)
          REFERENCES credit_applications (id, person_id, country_code)
        """

        down "ALTER TABLE credit_applications DROP CONSTRAINT credit_applications_previous_fkey"
      end

      statement :guard_function do
        up """
        CREATE FUNCTION credit_applications_guard() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF OLD.state IN ('approved', 'rejected', 'cancelled') THEN
            RAISE EXCEPTION 'application % is %, a final state', OLD.id, OLD.state
              USING ERRCODE = 'check_violation', CONSTRAINT = 'credit_applications_final_state';
          END IF;
          NEW.lock_version := OLD.lock_version + 1;
          RETURN NEW;
        END
        $$
        """

        down "DROP FUNCTION credit_applications_guard()"
      end

      # Final states never change, and every change increments the version
      statement :guard_trigger do
        up """
        CREATE TRIGGER credit_applications_guard BEFORE UPDATE ON credit_applications
          FOR EACH ROW EXECUTE FUNCTION credit_applications_guard()
        """

        down "DROP TRIGGER credit_applications_guard ON credit_applications"
      end
    end
  end

  audit do
    immutable [:person_id, :previous_application_id, :currency, :channel, :submitted_at]
  end

  actions do
    defaults [:read]

    read :visible do
      description """
      Applications in every country where the actor works, newest first; in every
      country for admins and auditors. Out of the actor's countries, an application
      does not exist for them.
      """

      multitenancy :allow_global
      pagination keyset?: true, required?: false, default_limit: 25, max_page_size: 100
      prepare fn query, _context -> Ash.Query.default_sort(query, submitted_at: :desc) end
    end

    create :submit do
      description """
      Receives an application in the tenant's country: resolves its holder, records
      their consent and starts it in submitted with its first revision. The state and
      the submission time are the server's.
      """

      accept [:amount_minor, :monthly_income_minor, :currency, :channel]

      argument :holder, Fides.Origination.Holder do
        description "The holder's document and data, checked against each other."
        allow_nil? false
        sensitive? true
      end

      argument :consent_text_version, :string do
        description "The version of the consent text the holder accepted."
        allow_nil? false
        constraints max_length: 64
      end

      change Changes.ResolveHolder
      change Changes.RecordConsent
      change Changes.Start
    end

    create :reapply do
      description """
      Retries a rejected or cancelled application as a new one of the same holder,
      with new terms and consent. Each application is retried once.
      """

      accept [:amount_minor, :monthly_income_minor, :channel]
      argument :previous_application_id, :uuid, allow_nil?: false

      argument :consent_text_version, :string do
        allow_nil? false
        constraints max_length: 64
      end

      change Changes.Retry
      change Changes.RecordConsent
      change Changes.Start
    end

    update :transition do
      description """
      Moves the application to another state, if its country's life cycle allows it
      for the actor. Fails without changes when the application is no longer in the
      version the actor expects.
      """

      accept []
      require_atomic? false
      argument :to, :atom, allow_nil?: false, constraints: [one_of: Lifecycle.states()]
      argument :reason, :string, constraints: [max_length: 1000]
      argument :expected_version, :integer, allow_nil?: false

      argument :policy_version_id, :uuid do
        description "The policy version the system evaluated with, when it leaves evaluating."
      end

      change Changes.Transition
    end

    update :respond do
      description """
      Answers a request for information: the corrected terms become the next revision,
      and the application goes back to validation.
      """

      accept []
      require_atomic? false
      argument :amount_minor, :integer, allow_nil?: false, constraints: [min: 1]
      argument :monthly_income_minor, :integer, allow_nil?: false, constraints: [min: 1]
      argument :expected_version, :integer, allow_nil?: false

      validate attribute_equals(:state, :info_requested),
        message: "only an application waiting for information takes an answer",
        before_action?: true

      change {Changes.Transition,
              to: :validating, reason: "answer to a request for information", answer?: true}

      change Changes.NextRevision
    end

    update :reevaluate do
      description """
      Sends an application waiting for review back to evaluation, for a cause such as
      a new policy version or new bank data. Only the system does.
      """

      accept []
      require_atomic? false
      argument :cause, :string, allow_nil?: false, constraints: [max_length: 1000]
      argument :expected_version, :integer, allow_nil?: false

      change {Changes.Transition, to: :evaluating}
    end
  end

  policies do
    policy action(:visible) do
      authorize_if SystemActor
      authorize_if {GlobalRole, roles: [:admin, :auditor]}
      authorize_if {InScopedCountry, roles: [:analyst, :risk_manager]}
    end

    policy action(:read) do
      authorize_if SystemActor
      authorize_if {GlobalRole, roles: [:admin, :auditor]}
      authorize_if {ScopedRole, roles: [:analyst, :risk_manager]}
    end

    policy action([:submit, :reapply, :respond]) do
      authorize_if SystemActor
      authorize_if {ScopedRole, roles: [:analyst]}
    end

    # The life cycle then decides which transitions each actor may make
    policy action(:transition) do
      authorize_if SystemActor
      authorize_if {ScopedRole, roles: [:analyst, :risk_manager]}
    end

    policy action(:reevaluate) do
      authorize_if SystemActor
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
      description "The holder."
      allow_nil? false
      public? true
    end

    attribute :previous_application_id, :uuid do
      description "The application this one retries."
      public? true
    end

    attribute :revision, :integer do
      description "Number of the current revision."
      allow_nil? false
      public? true
      default 1
    end

    attribute :currency, :string do
      allow_nil? false
      public? true
      constraints match: ~r/^[A-Z]{3}$/
    end

    attribute :amount_minor, :integer do
      description "Amount requested, in minor units, as in the current revision."
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :monthly_income_minor, :integer do
      description "Declared monthly income, in minor units, as in the current revision."
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :state, :atom do
      allow_nil? false
      public? true
      default :submitted
      constraints one_of: Lifecycle.states()
    end

    attribute :lock_version, :integer do
      description "Incremented by the database on every change."
      allow_nil? false
      public? true
      default 1
    end

    attribute :policy_version_id, :uuid do
      description "The policy version of the last evaluation."
      public? true
    end

    attribute :channel, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:api, :form, :chat]
    end

    attribute :submitted_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    timestamps()
  end

  classification do
    attribute :id, :pseudonymous
    attribute :country_code, :public
    attribute :person_id, :pseudonymous
    attribute :previous_application_id, :pseudonymous
    attribute :revision, :public
    attribute :currency, :public
    attribute :amount_minor, :financial
    attribute :monthly_income_minor, :financial
    attribute :state, :public
    attribute :lock_version, :public
    attribute :policy_version_id, :pseudonymous
    attribute :channel, :public
    attribute :submitted_at, :public
    attribute :inserted_at, :public
    attribute :updated_at, :public
  end

  relationships do
    has_many :revisions, Fides.Origination.ApplicationRevision do
      destination_attribute :application_id
      sort number: :asc
    end
  end

  identities do
    identity :one_open_per_holder, [:person_id],
      where: expr(state not in [:approved, :rejected, :cancelled]),
      message: "already has an application in progress"

    identity :retried_once, [:previous_application_id], message: "has already been retried"
  end
end
