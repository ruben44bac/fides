defmodule FidesWeb.ContentSecurityPolicy do
  @moduledoc """
  Adds a per-request nonce to the Content-Security-Policy that the router sets with
  `put_secure_browser_headers`. The nonce authorizes the inline theme script of the
  root layout and no other inline script.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    nonce = 18 |> :crypto.strong_rand_bytes() |> Base.encode64()
    conn = assign(conn, :csp_nonce, nonce)

    case get_resp_header(conn, "content-security-policy") do
      [policy] -> put_resp_header(conn, "content-security-policy", add_nonce(policy, nonce))
      _none -> conn
    end
  end

  defp add_nonce(policy, nonce) do
    String.replace(policy, "script-src 'self'", "script-src 'self' 'nonce-#{nonce}'",
      global: false
    )
  end
end
