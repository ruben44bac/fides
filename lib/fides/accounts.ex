defmodule Fides.Accounts do
  @moduledoc """
  Accounts context: the back-office staff, the countries each of them works in, and
  the tokens they sign in with.
  """

  use Fides.Platform.Domain,
    boundary: [deps: [Fides.Platform], exports: [Demo, Seeds, StaffUser, Idempotency]]

  resources do
    resource Fides.Accounts.StaffUser do
      define :seed_staff_user, action: :seed
      define :get_staff_user, action: :read, get_by: [:id]
      define :unlock_staff_user, action: :unlock
    end

    resource Fides.Accounts.StaffScope do
      define :grant_scope, action: :grant, args: [:user_id, :role]
      define :revoke_scope, action: :revoke
      define :list_scopes, action: :read
      define :list_all_scopes, action: :all_countries
    end

    resource Fides.Accounts.StaffToken
    resource Fides.Accounts.IdempotencyKey
  end

  @doc """
  Signs a staff user in with their email, password and current TOTP code, and
  returns a short-lived bearer token with its claims.
  """
  defdelegate sign_in(email, password, totp_code), to: Fides.Accounts.SignIn

  @doc "A staff user as policies see them: with the scopes that authorize them now."
  @spec load_actor(Fides.Accounts.StaffUser.t()) :: Fides.Accounts.StaffUser.t()
  def load_actor(user), do: Ash.load!(user, :active_scopes, authorize?: false, domain: __MODULE__)
end
