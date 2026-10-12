defmodule Fides.Origination.CreditApplication.Changes.Start do
  @moduledoc """
  Starts an application in submitted, with the server's submission time, and adds its
  first revision with the terms it was submitted with.
  """

  use Ash.Resource.Change

  alias Fides.Origination.CreditApplication.Changes.NextRevision

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.force_change_attribute(:state, :submitted)
    |> Ash.Changeset.force_change_attribute(:revision, 1)
    |> Ash.Changeset.force_change_attribute(:submitted_at, DateTime.utc_now())
    |> NextRevision.add_after_action(:submitted)
  end
end
