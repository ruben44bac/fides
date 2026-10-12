defmodule Fides.Origination.LifecycleTransition do
  @moduledoc """
  A transition of a country's life cycle, as the seeds write it from the code. An
  application only changes state along a transition of its country: the database
  refuses any other change. Who may make the move, and under which condition, is for
  the application's actions to check.
  """

  use Fides.Platform.Resource,
    domain: Fides.Origination

  postgres do
    table "lifecycle_transitions"
    repo Fides.Platform.Repo

    # Both ends are states of the same country
    custom_statements do
      statement :state_foreign_keys do
        up """
        ALTER TABLE lifecycle_transitions
          ADD CONSTRAINT lifecycle_transitions_from_state_fkey
            FOREIGN KEY (country_code, from_state) REFERENCES lifecycle_states (country_code, state),
          ADD CONSTRAINT lifecycle_transitions_to_state_fkey
            FOREIGN KEY (country_code, to_state) REFERENCES lifecycle_states (country_code, state)
        """

        down """
        ALTER TABLE lifecycle_transitions
          DROP CONSTRAINT lifecycle_transitions_to_state_fkey,
          DROP CONSTRAINT lifecycle_transitions_from_state_fkey
        """
      end
    end
  end

  actions do
    defaults [:read]

    create :seed do
      description "Adds a transition the code declares for the tenant's country."
      accept [:from_state, :to_state]
    end

    destroy :retire do
      description "Removes a transition the code no longer declares for the tenant's country."
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action([:seed, :retire]) do
      authorize_if Fides.Platform.Checks.SystemActor
    end
  end

  multitenancy do
    strategy :attribute
    attribute :country_code
  end

  attributes do
    attribute :country_code, Fides.Platform.Types.CountryCode do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :from_state, :atom do
      primary_key? true
      allow_nil? false
      public? true
      constraints one_of: Fides.Origination.Lifecycle.states()
    end

    attribute :to_state, :atom do
      primary_key? true
      allow_nil? false
      public? true
      constraints one_of: Fides.Origination.Lifecycle.states()
    end

    timestamps()
  end

  classification do
    attribute :country_code, :public
    attribute :from_state, :public
    attribute :to_state, :public
    attribute :inserted_at, :public
    attribute :updated_at, :public
  end
end
