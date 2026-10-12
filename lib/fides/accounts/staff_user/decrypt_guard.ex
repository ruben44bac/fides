defmodule Fides.Accounts.StaffUser.DecryptGuard do
  @moduledoc """
  Decides who may decrypt a staff user's encrypted fields: only the sign-in, to
  check a TOTP code, which asks for it in the load's context.
  """

  @spec approve(module(), [struct()], atom(), map()) :: :ok | {:error, String.t()}
  def approve(_resource, _records, :totp_secret, %{source_context: %{fides: %{decrypt: :sign_in}}}),
      do: :ok

  def approve(_resource, _records, field, _context),
    do: {:error, "#{field} is only decrypted to check a sign-in code"}
end
