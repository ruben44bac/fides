defmodule Fides.Orchestration.CaseFact do
  @moduledoc """
  Something an agent found about an application, as the orchestrator confirmed it:
  a name and a value, the agent and tool that found it, the application's version at
  the time, and a hash of the value.

  Facts are the memory agents share: agents do not talk to each other, they read the
  facts of the case. A fact is never changed or deleted; a newer fact with the same
  name is the current one, and the older one stays as evidence.
  """

  use Fides.Platform.Resource,
    domain: Fides.Orchestration

  alias Fides.Platform.Checks.GlobalRole
  alias Fides.Platform.Checks.ScopedRole
  alias Fides.Platform.Checks.SystemActor

  postgres do
    table "case_facts"
    repo Fides.Platform.Repo

    custom_indexes do
      index [:application_id, :name, :inserted_at]
    end
  end

  audit do
    append_only? true
  end

  actions do
    defaults [:read]

    create :record do
      accept [:application_id, :name, :value, :agent, :tool, :lock_version]

      change fn changeset, _context ->
        name = Ash.Changeset.get_attribute(changeset, :name)
        value = Ash.Changeset.get_attribute(changeset, :value)
        Ash.Changeset.force_change_attribute(changeset, :hash, hash(name, value))
      end
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

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints max_length: 64
    end

    attribute :value, :map, allow_nil?: false, public?: true
    attribute :agent, :atom, allow_nil?: false, public?: true

    attribute :tool, :string do
      description "The tool the agent found the fact with, such as identity.validate_document."
      allow_nil? false
      public? true
    end

    attribute :lock_version, :integer do
      description "The version of the application the fact was found at."
      allow_nil? false
      public? true
    end

    attribute :hash, :binary do
      description "SHA-256 of the name and the value as JSON."
      allow_nil? false
    end

    create_timestamp :inserted_at
  end

  classification do
    attribute :id, :pseudonymous
    attribute :country_code, :public
    attribute :application_id, :pseudonymous
    attribute :name, :public
    attribute :value, :internal
    attribute :agent, :public
    attribute :tool, :public
    attribute :lock_version, :public
    attribute :hash, :internal
    attribute :inserted_at, :public
  end

  @doc "The hash of a fact: the same name and value always give the same hash."
  @spec hash(String.t(), map()) :: binary()
  def hash(name, value), do: :crypto.hash(:sha256, name <> ":" <> Jason.encode!(value))
end
