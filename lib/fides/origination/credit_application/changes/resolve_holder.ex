defmodule Fides.Origination.CreditApplication.Changes.ResolveHolder do
  @moduledoc """
  Finds or creates the application's holder in Identity, which checks the document
  against the holder's data. An invalid holder creates nothing.
  """

  use Ash.Resource.Change

  alias Fides.Platform.SystemActor

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      holder = Ash.Changeset.get_argument(changeset, :holder)

      case Fides.Identity.resolve_person(holder, tenant: changeset.tenant, actor: actor()) do
        {:ok, person} -> Ash.Changeset.force_change_attribute(changeset, :person_id, person.id)
        {:error, error} -> Ash.Changeset.add_error(changeset, error)
      end
    end)
  end

  defp actor, do: SystemActor.new(:origination)
end
