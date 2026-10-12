defmodule Fides.Origination.CreditApplication.Changes.NextRevision do
  @moduledoc """
  Makes the answered terms the application's next revision: the application copies
  them, and the revision is added in the same transaction.
  """

  use Ash.Resource.Change

  alias Fides.Origination.ApplicationRevision

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.force_change_attribute(:revision, changeset.data.revision + 1)
    |> copy_argument(:amount_minor)
    |> copy_argument(:monthly_income_minor)
    |> add_after_action(:info_response)
  end

  @doc "Adds the application's current terms as its revision once the application is saved."
  @spec add_after_action(Ash.Changeset.t(), atom()) :: Ash.Changeset.t()
  def add_after_action(changeset, cause) do
    Ash.Changeset.after_action(changeset, fn _changeset, application ->
      revision = %{
        application_id: application.id,
        number: application.revision,
        amount_minor: application.amount_minor,
        monthly_income_minor: application.monthly_income_minor,
        cause: cause
      }

      ApplicationRevision
      |> Ash.Changeset.for_create(:add, revision,
        tenant: application.country_code,
        authorize?: false
      )
      |> Ash.create()
      |> case do
        {:ok, _revision} -> {:ok, application}
        {:error, error} -> {:error, error}
      end
    end)
  end

  defp copy_argument(changeset, name) do
    Ash.Changeset.force_change_attribute(
      changeset,
      name,
      Ash.Changeset.get_argument(changeset, name)
    )
  end
end
