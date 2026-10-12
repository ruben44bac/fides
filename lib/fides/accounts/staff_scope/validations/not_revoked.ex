defmodule Fides.Accounts.StaffScope.Validations.NotRevoked do
  @moduledoc """
  Refuses to revoke a scope twice, which would overwrite who revoked it and when.
  Checked in the UPDATE itself, so two admins revoking at once cannot both succeed.
  """

  use Ash.Resource.Validation

  import Ash.Expr

  alias Ash.Error.Changes.InvalidAttribute

  @message "is already revoked"

  @impl true
  def validate(changeset, _opts, _context) do
    if is_nil(changeset.data.revoked_at),
      do: :ok,
      else: {:error, field: :revoked_at, message: @message}
  end

  @impl true
  def atomic(_changeset, _opts, _context) do
    {:atomic, [:revoked_at], expr(not is_nil(revoked_at)),
     expr(error(^InvalidAttribute, %{field: :revoked_at, value: revoked_at, message: ^@message}))}
  end
end
