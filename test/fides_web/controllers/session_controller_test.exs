defmodule FidesWeb.SessionControllerTest do
  # Signs demo-like staff in: the sandbox is shared with the sign-in's own queries
  use FidesWeb.ConnCase, async: false

  alias Fides.Accounts.Totp
  alias Fides.Factory

  setup do
    {user, secret} = Factory.staff_user()
    %{user: user, secret: secret}
  end

  defp sign_in(conn, user, password, code) do
    post(conn, ~p"/backoffice/sign-in", %{
      "session" => %{
        "email" => to_string(user.email),
        "password" => password,
        "totp_code" => code
      }
    })
  end

  test "shows the sign-in form", %{conn: conn} do
    response = get(conn, ~p"/backoffice/sign-in")
    assert html_response(response, 200) =~ "id=\"sign-in-form\""
  end

  test "the password and the current code open a session that the backoffice accepts", ctx do
    response = sign_in(ctx.conn, ctx.user, Factory.staff_password(), Totp.code(ctx.secret))

    assert redirected_to(response) == ~p"/backoffice"
    assert is_binary(get_session(response, FidesWeb.StaffSession.session_key()))

    # The session carries the staff user into the next request
    next = response |> recycle() |> get(~p"/backoffice/sign-out")
    assert next.status in [404, 405] or redirected_to(next) != ~p"/backoffice/sign-in"
  end

  test "a wrong code, a wrong password or an unknown email get the same refusal", ctx do
    for {email, password, code} <- [
          {ctx.user.email, Factory.staff_password(), Factory.wrong_code(ctx.secret)},
          {ctx.user.email, "not the password", Totp.code(ctx.secret)},
          {"nobody@fides.test", Factory.staff_password(), Totp.code(ctx.secret)}
        ] do
      response =
        post(ctx.conn, ~p"/backoffice/sign-in", %{
          "session" => %{"email" => to_string(email), "password" => password, "totp_code" => code}
        })

      assert html_response(response, 401) =~ "id=\"sign-in-error\""
      refute get_session(response, FidesWeb.StaffSession.session_key())
    end
  end

  test "without a session the backoffice sends to the sign-in", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/backoffice")) == ~p"/backoffice/sign-in"
  end

  test "signing out revokes the session's token", ctx do
    conn = staff_session(ctx.conn, ctx.user, ctx.secret)
    token = get_session(conn, FidesWeb.StaffSession.session_key())

    assert html_response(get(conn, ~p"/backoffice"), 200) =~ "Inbox"

    signed_out = delete(conn, ~p"/backoffice/sign-out")
    assert redirected_to(signed_out) == ~p"/backoffice/sign-in"

    # The token is gone for good, even if someone kept it
    again = Plug.Test.init_test_session(ctx.conn, %{FidesWeb.StaffSession.session_key() => token})
    assert redirected_to(get(again, ~p"/backoffice")) == ~p"/backoffice/sign-in"
  end
end
