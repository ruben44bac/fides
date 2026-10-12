defmodule Fides.Origination.LifecycleState do
  @moduledoc """
  A state of a country's life cycle, as the seeds write it from the code. An
  application is only ever in a state of its country: the database refuses any other,
  and refuses to remove a state while an application is in it.
  """

  use Fides.Platform.Resource,
    domain: Fides.Origination

  postgres do
    table "lifecycle_states"
    repo Fides.Platform.Repo
  end

  actions do
    defaults [:read]

    create :seed do
      description "Adds a state the code declares for the tenant's country."
      accept [:state]
    end

    destroy :retire do
      description "Removes a state the code no longer declares for the tenant's country."
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

    attribute :state, :atom do
      primary_key? true
      allow_nil? false
      public? true
      constraints one_of: Fides.Origination.Lifecycle.states()
    end

    timestamps()
  end

  classification do
    attribute :country_code, :public
    attribute :state, :public
    attribute :inserted_at, :public
    attribute :updated_at, :public
  end
end
