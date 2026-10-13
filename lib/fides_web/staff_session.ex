defmodule FidesWeb.StaffSession do
  @moduledoc """
  The staff's browser session: the token the sign-in issued travels in the session,
  and each request turns it back into the staff user, with their active scopes, the
  same way the API does with a bearer token. A request without one goes to the
  sign-in.
  """

  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2, put_flash: 3]

  alias AshAuthentication.Plug.Helpers

  @session_key "staff_user_token"

  @impl true
  def init(step), do: step

  @impl true
  def call(conn, :fetch_staff), do: fetch_staff(conn, [])
  def call(conn, :require_staff), do: conn |> fetch_staff([]) |> require_staff([])

  @doc "The session key the token is kept under."
  @spec session_key() :: String.t()
  def session_key, do: @session_key

  @doc "Keeps a token the sign-in issued, in a fresh session."
  @spec sign_in(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def sign_in(conn, token) do
    conn
    |> configure_session(renew: true)
    |> put_session(@session_key, token)
  end

  @doc "Revokes the session's token and drops the session."
  @spec sign_out(Plug.Conn.t()) :: Plug.Conn.t()
  def sign_out(conn) do
    conn
    |> Helpers.revoke_session_tokens(:fides)
    |> configure_session(drop: true)
  end

  @doc "Assigns `current_staff_user` from the session, or nil."
  @spec fetch_staff(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def fetch_staff(conn, _opts), do: Helpers.retrieve_from_session(conn, :fides)

  @doc "Lets only a signed-in staff user through, as the actor of the request."
  @spec require_staff(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def require_staff(conn, _opts) do
    case conn.assigns[:current_staff_user] do
      %{} = user ->
        conn
        |> Ash.PlugHelpers.set_actor(user)
        |> assign(:current_scope, FidesWeb.StaffScope.new(user))

      _nobody ->
        conn
        |> put_flash(:error, "Sign in to continue.")
        |> redirect(to: "/backoffice/sign-in")
        |> halt()
    end
  end
end
