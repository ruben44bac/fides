defmodule Fides.Accounts.StaffScope.Validations.NoGlobalRole do
  @moduledoc """
  Refuses a scope for a staff user with a global role: admins and auditors never act
  through country scopes.
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    user_id = Ash.Changeset.get_attribute(changeset, :user_id)

    case Ash.get(Fides.Accounts.StaffUser, user_id, authorize?: false) do
      {:ok, %{global_role: nil}} ->
        :ok

      {:ok, %{global_role: role}} ->
        {:error,
         field: :user_id, message: "is #{role}, a role that never acts through country scopes"}

      {:error, _not_found} ->
        {:error, field: :user_id, message: "is not a staff user"}
    end
  end
end
