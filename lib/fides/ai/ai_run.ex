defmodule Fides.AI.AiRun do
  @moduledoc """
  One invocation of a capability: which model, for which subject, the hashes of the
  prompt and of what went in, what came out, whether the guardrails passed, what it
  cost, and whether the model answered or the template stood in. Runs are never
  changed or deleted.
  """

  use Fides.Platform.Resource, domain: Fides.AI

  alias Fides.Platform.Checks.Agent
  alias Fides.Platform.Checks.GlobalRole
  alias Fides.Platform.Checks.ScopedRole
  alias Fides.Platform.Checks.SystemActor

  postgres do
    table "ai_runs"
    repo Fides.Platform.Repo

    custom_indexes do
      index [:subject_id, :inserted_at]
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
        :capability,
        :model,
        :subject_id,
        :lock_version,
        :prompt_hash,
        :input_hash,
        :output,
        :guardrails,
        :outcome,
        :tokens_in,
        :tokens_out,
        :cost_usd,
        :latency_ms,
        :shadow,
        :error
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
      authorize_if {Agent, names: [:ai]}
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

    attribute :capability, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:case_brief]
    end

    attribute :model, :string do
      description "The model that answered, or was asked: the simulated one by default."
      allow_nil? false
      public? true
    end

    attribute :subject_id, :uuid do
      description "What the run was about: the application, for a brief."
      allow_nil? false
      public? true
    end

    attribute :lock_version, :integer do
      description "The version of the application the run worked on."
      allow_nil? false
      public? true
    end

    attribute :prompt_hash, :binary, allow_nil?: false
    attribute :input_hash, :binary, allow_nil?: false

    attribute :output, :map do
      description "What was shown: the model's answer when it passed the guardrails, otherwise the template's."
      allow_nil? false
      public? true
    end

    attribute :guardrails, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:passed, :failed, :skipped]
    end

    attribute :outcome, :atom do
      description "model when the model's answer was used, fallback when the template stood in."
      allow_nil? false
      public? true
      constraints one_of: [:model, :fallback]
    end

    attribute :tokens_in, :integer, allow_nil?: false, public?: true, default: 0
    attribute :tokens_out, :integer, allow_nil?: false, public?: true, default: 0
    attribute :cost_usd, :decimal, public?: true
    attribute :latency_ms, :integer, allow_nil?: false, public?: true

    attribute :shadow, :boolean do
      description "Whether the run was a shadow model's, never shown."
      allow_nil? false
      public? true
      default false
    end

    attribute :error, :string, public?: true

    create_timestamp :inserted_at
  end

  classification do
    attribute :id, :pseudonymous
    attribute :country_code, :public
    attribute :capability, :public
    attribute :model, :public
    attribute :subject_id, :pseudonymous
    attribute :lock_version, :public
    attribute :prompt_hash, :internal
    attribute :input_hash, :internal
    attribute :output, :internal
    attribute :guardrails, :public
    attribute :outcome, :public
    attribute :tokens_in, :internal
    attribute :tokens_out, :internal
    attribute :cost_usd, :internal
    attribute :latency_ms, :internal
    attribute :shadow, :public
    attribute :error, :internal
    attribute :inserted_at, :public
  end
end
