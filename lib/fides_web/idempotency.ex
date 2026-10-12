defmodule FidesWeb.Idempotency do
  @moduledoc """
  Runs each command of the API once per `Idempotency-Key` and staff user.

  The first request with a key runs, and the response it gets is kept. Repeating it
  with the same key and the same body gets that response again, without running the
  command; the same key with another body answers 422, and a key whose first request
  is still running answers 409. Commands without a key answer 422. A response the
  server failed to give (5xx) frees the key, so the command can be tried again.
  """

  @behaviour Plug

  import Plug.Conn

  alias Fides.Accounts.Idempotency
  alias FidesWeb.ApiError

  @commands ~w(transitions revisions reapply)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{method: "POST", path_info: path} = conn, _opts) do
    if command?(path), do: run_once(conn), else: conn
  end

  def call(conn, _opts), do: conn

  defp command?(["api", "applications"]), do: true
  defp command?(["api", "applications", _id, command]), do: command in @commands
  defp command?(_path), do: false

  defp run_once(conn) do
    case get_req_header(conn, "idempotency-key") do
      [key] when byte_size(key) in 1..255 ->
        claim(conn, key)

      _none ->
        ApiError.send(
          conn,
          422,
          "missing_idempotency_key",
          "the Idempotency-Key header is required"
        )
    end
  end

  defp claim(conn, key) do
    actor = Ash.PlugHelpers.get_actor(conn)

    case Idempotency.claim(actor.id, key, request_hash(conn)) do
      {:new, claimed} ->
        register_before_send(conn, &keep(&1, claimed))

      {:replay, kept} ->
        conn
        |> put_resp_content_type("application/vnd.api+json")
        |> send_resp(kept.response_status, Jason.encode!(kept.response_body))
        |> halt()

      {:error, :other_request} ->
        ApiError.send(
          conn,
          422,
          "idempotency_key_reused",
          "the Idempotency-Key was used with another request"
        )

      {:error, :busy} ->
        ApiError.send(
          conn,
          409,
          "idempotency_key_busy",
          "a request with this Idempotency-Key is still running"
        )
    end
  end

  defp request_hash(conn) do
    request = {conn.method, conn.request_path, conn.body_params}
    :crypto.hash(:sha256, :erlang.term_to_binary(request, [:deterministic]))
  end

  defp keep(conn, claimed) do
    if conn.status < 500 do
      Idempotency.complete(claimed, conn.status, body(conn.resp_body))
    else
      Idempotency.release(claimed)
    end

    conn
  end

  defp body(resp_body) do
    case Jason.decode(IO.iodata_to_binary(resp_body)) do
      {:ok, body} -> body
      {:error, _not_json} -> nil
    end
  end
end
