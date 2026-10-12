defmodule FidesWeb.AuthenticateStaff do
  @moduledoc """
  Lets a request through only with a staff bearer token: signed with the staff
  secret, issued here, not revoked or expired, and naming an active staff user. That
  user, with their active scopes, becomes the actor, and the request's writes are
  audited as theirs. Anything else is a 401, the same for every cause.
  """

  @behaviour Plug

  import Plug.Conn

  alias AshAuthentication.Plug.Helpers
  alias Fides.Accounts.StaffUser
  alias Fides.Platform.AuditContext
  alias FidesWeb.ApiError

  @impl true
  def init(opts), do: opts

  # Verified against the staff resource, the signature is checked before any claim
  # is read, and tokens of other resources are never considered
  @impl true
  def call(conn, _opts) do
    conn = Helpers.retrieve_from_bearer(conn, StaffUser)

    case conn.assigns do
      %{current_staff_user: %{} = user} ->
        conn |> Ash.PlugHelpers.set_actor(user) |> audit_as(user)

      _no_staff_user ->
        unauthorized(conn)
    end
  end

  @doc "Answers 401 in the API's error format."
  @spec unauthorized(Plug.Conn.t()) :: Plug.Conn.t()
  def unauthorized(conn),
    do: ApiError.send(conn, 401, "unauthorized", "a valid staff bearer token is required")

  # The request's process may serve the next request too, so the context ends with it
  defp audit_as(conn, user) do
    [
      actor: "staff_user:" <> user.id,
      reason: "#{conn.method} #{conn.request_path}",
      correlation_id: List.first(get_resp_header(conn, "x-request-id")),
      traceparent: List.first(get_req_header(conn, "traceparent"))
    ]
    |> Enum.reject(fn {_field, value} -> is_nil(value) end)
    |> AuditContext.put()

    register_before_send(conn, fn conn ->
      AuditContext.clear()
      conn
    end)
  end
end
