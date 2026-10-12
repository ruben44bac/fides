defmodule FidesWeb.StaffTokenController do
  @moduledoc """
  Issues bearer tokens to staff for their email, password and current TOTP code, and
  revokes the token a request carries.
  """

  use FidesWeb, :controller

  alias AshAuthentication.Plug.Helpers
  alias Fides.Accounts.StaffUser
  alias FidesWeb.AuthenticateStaff

  def create(conn, %{"email" => email, "password" => password, "totp_code" => code}) do
    case Fides.Accounts.sign_in(email, password, code) do
      {:ok, token, %{"exp" => expires_at}} ->
        json(conn, %{
          access_token: token,
          token_type: "Bearer",
          expires_in: expires_at - System.os_time(:second)
        })

      {:error, :authentication_failed} ->
        AuthenticateStaff.unauthorized(conn)
    end
  end

  def create(conn, _params), do: AuthenticateStaff.unauthorized(conn)

  def delete(conn, _params) do
    conn
    |> Helpers.revoke_bearer_tokens(StaffUser)
    |> send_resp(204, "")
  end
end
