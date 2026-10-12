defmodule Fides.Risk.PolicyVersion.Changes.RetireVersionInForce do
  @moduledoc """
  Retires the country's version in force in the transaction that publishes its
  successor, so a country never has two versions in force.
  """

  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      changeset.resource
      |> Ash.Query.filter(status == :published)
      |> Ash.bulk_update!(:retire, %{},
        tenant: changeset.tenant,
        authorize?: false,
        strategy: [:atomic, :stream]
      )

      changeset
    end)
  end
end
