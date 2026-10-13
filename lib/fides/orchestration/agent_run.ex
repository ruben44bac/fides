defmodule Fides.Orchestration.AgentRun do
  @moduledoc """
  One run of an agent on an application: which agent and version, the job and
  attempt that ran it, the application's version and a hash of what the agent was
  given, and what came of it. Runs are never changed or deleted.

  The outcome is `advance` when the orchestrator confirmed the agent's proposal,
  `superseded` when the application changed in the meantime and the proposal was
  dropped, `retry` when the agent runs again later, and `escalate` when the case needs
  a person.
  """

  use Fides.Platform.Resource,
    domain: Fides.Orchestration

  alias Fides.Platform.Checks.GlobalRole
  alias Fides.Platform.Checks.ScopedRole
  alias Fides.Platform.Checks.SystemActor

  postgres do
    table "agent_runs"
    repo Fides.Platform.Repo

    custom_indexes do
      index [:application_id, :inserted_at]
    end
  end

  # A record of work, not a change to anyone's data
  audit do
    capture? false
    append_only? true
  end

  actions do
    defaults [:read]

    create :record do
      accept [
        :application_id,
        :agent,
        :agent_version,
        :job_id,
        :attempt,
        :lock_version,
        :input_hash,
        :outcome,
        :proposed_state,
        :reason,
        :duration_ms
      ]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if SystemActor
      authorize_if {GlobalRole, roles: [:admin, :auditor]}
      authorize_if {ScopedRole, roles: [:analyst, :risk_manager]}
    end

    policy action(:record) do
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

    attribute :application_id, :uuid, allow_nil?: false, public?: true
    attribute :agent, :atom, allow_nil?: false, public?: true

    attribute :agent_version, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :job_id, :integer, allow_nil?: false, public?: true
    attribute :attempt, :integer, allow_nil?: false, public?: true

    attribute :lock_version, :integer do
      description "The version of the application the agent worked on."
      allow_nil? false
      public? true
    end

    attribute :input_hash, :binary do
      description "SHA-256 of what the agent was given, which carries no personal data."
      allow_nil? false
    end

    attribute :outcome, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:advance, :superseded, :retry, :escalate]
    end

    attribute :proposed_state, :atom do
      description "The state the agent proposed, when it proposed a move."
      public? true
    end

    attribute :reason, :string, public?: true
    attribute :duration_ms, :integer, allow_nil?: false, public?: true

    create_timestamp :inserted_at
  end

  classification do
    attribute :id, :pseudonymous
    attribute :country_code, :public
    attribute :application_id, :pseudonymous
    attribute :agent, :public
    attribute :agent_version, :public
    attribute :job_id, :internal
    attribute :attempt, :internal
    attribute :lock_version, :public
    attribute :input_hash, :internal
    attribute :outcome, :public
    attribute :proposed_state, :public
    attribute :reason, :internal
    attribute :duration_ms, :internal
    attribute :inserted_at, :public
  end
end
