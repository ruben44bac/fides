defmodule FidesWeb.AuthenticateStaff do
  @moduledoc """
  Lets a request through only with a staff bearer token: signed with the staff
  secret, issued here, not revoked or expired, and naming an active staff user. That
  user, with their active scopes, becomes the actor. Anything else is a 401, the same
  for every cause.
  """

  @behaviour Plug

  import Plug.Conn

  alias AshAuthentication.Plug.Helpers
  alias Fides.Accounts.StaffUser

  @impl true
  def init(opts), do: opts

  # Verified against the staff resource, the signature is checked before any claim
  # is read, and tokens of other resources are never considered
  @impl true
  def call(conn, _opts) do
    conn = Helpers.retrieve_from_bearer(conn, StaffUser)

    case conn.assigns do
      %{current_staff_user: %{} = user} -> Ash.PlugHelpers.set_actor(conn, user)
      _no_staff_user -> conn |> unauthorized() |> halt()
    end
  end

  @doc "Answers 401 in the API's error format."
  @spec unauthorized(Plug.Conn.t()) :: Plug.Conn.t()
  def unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{errors: [%{status: "401", title: "Unauthorized"}]}))
  end
end
