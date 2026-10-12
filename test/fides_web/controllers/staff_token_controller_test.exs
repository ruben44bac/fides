defmodule FidesWeb.StaffTokenControllerTest do
  use FidesWeb.ConnCase, async: true

  alias Fides.Accounts.StaffUser
  alias Fides.Accounts.Totp
  alias Fides.Factory

  setup %{conn: conn} do
    {user, secret} = Factory.staff_user()

    %{
      conn: put_req_header(conn, "accept", "application/json"),
      user: user,
      secret: secret,
      credentials: %{email: to_string(user.email), password: Factory.staff_password()}
    }
  end

  defp issue(ctx, extra \\ %{}) do
    post(ctx.conn, ~p"/api/auth/token", Map.merge(ctx.credentials, extra))
  end

  defp issued_token(ctx) do
    issue(ctx, %{totp_code: Totp.code(ctx.secret)})
    |> json_response(200)
    |> Map.fetch!("access_token")
  end

  defp with_token(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp revoke(conn, token), do: conn |> with_token(token) |> delete(~p"/api/auth/token")

  # An unsigned token whose payload claims anything
  defp forged(claims) do
    "eyJhbGciOiJIUzI1NiJ9." <> Base.url_encode64(Jason.encode!(claims), padding: false) <> ".x"
  end

  test "issues a bearer token with the second factor", ctx do
    conn = issue(ctx, %{totp_code: Totp.code(ctx.secret)})

    assert %{"access_token" => token, "token_type" => "Bearer", "expires_in" => expires_in} =
             json_response(conn, 200)

    assert expires_in in 890..900
    assert {:ok, _claims, StaffUser} = AshAuthentication.Jwt.verify(token, :fides)
  end

  test "refuses a token without the second factor, with the same answer for every cause", ctx do
    responses = [
      issue(ctx),
      issue(ctx, %{totp_code: Factory.wrong_code(ctx.secret)}),
      issue(ctx, %{password: "not the password", totp_code: Totp.code(ctx.secret)}),
      issue(ctx, %{email: "nobody@fides.test", totp_code: Totp.code(ctx.secret)})
    ]

    for conn <- responses do
      assert json_response(conn, 401) == %{
               "errors" => [%{"status" => "401", "title" => "Unauthorized"}]
             }
    end
  end

  test "a staff route answers 401 without a valid staff token", ctx do
    {:ok, foreign, _claims} =
      AshAuthentication.Jwt.token_for_user(ctx.user, %{"purpose" => "user"},
        signing_secret: "a secret this app does not use"
      )

    assert ctx.conn |> delete(~p"/api/auth/token") |> json_response(401)

    forged = for sub <- [1, nil, ["x"], %{}, true, "staff_user?id=x"], do: forged(%{"sub" => sub})

    for token <- ["", "garbage", "a.b.c", foreign | forged] do
      assert ctx.conn |> revoke(token) |> json_response(401), inspect(token)
    end
  end

  test "a revoked token stops working on the next request", ctx do
    token = issued_token(ctx)

    assert ctx.conn |> revoke(token) |> response(204)
    assert ctx.conn |> revoke(token) |> json_response(401)
  end

  test "a token whose stored row is gone stops working", ctx do
    token = issued_token(ctx)
    {1, _deleted} = Fides.Platform.Repo.delete_all("staff_tokens")

    assert ctx.conn |> revoke(token) |> json_response(401)
  end

  test "a token stops working when its user is locked", ctx do
    token = issued_token(ctx)

    Factory.update_staff_user(ctx.user, status: "locked")

    assert ctx.conn |> revoke(token) |> json_response(401)
  end

  test "the token's staff user, with their scopes, becomes the actor", ctx do
    conn = ctx.conn |> with_token(issued_token(ctx)) |> FidesWeb.AuthenticateStaff.call([])

    refute conn.halted
    assert %StaffUser{id: id, active_scopes: []} = Ash.PlugHelpers.get_actor(conn)
    assert id == ctx.user.id
  end
end
