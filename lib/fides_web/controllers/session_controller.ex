defmodule FidesWeb.SessionController do
  @moduledoc """
  Signs staff in and out of the backoffice: the password and the current TOTP code
  give a session, and signing out revokes its token.
  """

  use FidesWeb, :controller

  alias FidesWeb.StaffSession

  def new(conn, _params), do: render_form(conn, %{}, nil)

  def create(conn, %{
        "session" => %{"email" => email, "password" => password, "totp_code" => code}
      }) do
    case Fides.Accounts.sign_in(email, password, code) do
      {:ok, token, _claims} ->
        conn
        |> StaffSession.sign_in(token)
        |> redirect(to: ~p"/backoffice")

      {:error, :authentication_failed} ->
        conn
        |> put_status(:unauthorized)
        |> render_form(%{"email" => email}, "The email, the password or the code is not right.")
    end
  end

  def create(conn, _params), do: render_form(conn, %{}, "Email, password and code are required.")

  def delete(conn, _params) do
    conn
    |> StaffSession.sign_out()
    |> redirect(to: ~p"/backoffice/sign-in")
  end

  defp render_form(conn, values, error) do
    render(conn, :new,
      form: Phoenix.Component.to_form(values, as: :session),
      error: error,
      page_title: "Sign in"
    )
  end
end
