defmodule FidesWeb.ContentSecurityPolicyTest do
  use FidesWeb.ConnCase, async: true

  test "browser pages get a CSP whose nonce matches the inline script", %{conn: conn} do
    conn = get(conn, ~p"/backoffice/sign-in")

    [policy] = get_resp_header(conn, "content-security-policy")
    [_, nonce] = Regex.run(~r/'nonce-([^']+)'/, policy)

    assert policy =~ "default-src 'self'"
    assert policy =~ "frame-ancestors 'none'"
    assert html_response(conn, 200) =~ ~s(<script nonce="#{nonce}">)
  end

  test "each request gets a new nonce", %{conn: conn} do
    nonce = fn ->
      conn |> get(~p"/backoffice/sign-in") |> get_resp_header("content-security-policy")
    end

    refute nonce.() == nonce.()
  end
end
