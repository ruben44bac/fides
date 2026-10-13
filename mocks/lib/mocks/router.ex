defmodule Mocks.Router do
  @moduledoc """
  The simulated providers' endpoints, and the receiver of Fides' webhooks. Each
  provider answers at `POST /providers/:adapter/profiles` with a JSON body carrying
  `request_id`, `document_type` and `document`, in the format of its country. The
  receiver takes signed deliveries at `POST /webhooks` and lists them at
  `GET /webhooks`. The knobs in `Mocks.Settings` make them slow, fail or answer badly.
  """

  use Plug.Router

  alias Mocks.Providers
  alias Mocks.Receiver
  alias Mocks.Settings

  plug Plug.Logger, log: :debug
  plug :match

  plug Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason,
    body_reader: {Mocks.BodyReader, :read_body, []}

  plug :dispatch

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  post "/providers/:adapter/profiles" do
    with true <- adapter in Providers.adapters() || :unknown_adapter,
         %{"request_id" => request_id, "document" => document} when is_binary(document) <-
           conn.body_params do
      Process.sleep(Settings.latency_ms())

      conn
      |> get_req_header("x-mock-scenario")
      |> List.first()
      |> Settings.scenario()
      |> respond(conn, adapter, request_id, document)
    else
      :unknown_adapter -> send_json(conn, 404, %{error: "unknown provider #{adapter}"})
      _params -> send_json(conn, 400, %{error: "request_id and document are required"})
    end
  end

  post "/webhooks" do
    signature = conn |> get_req_header("x-signature") |> List.first()

    cond do
      Settings.receiver_down?() ->
        send_json(conn, 503, %{error: "the receiver is down"})

      Receiver.verify(signature, conn.assigns[:raw_body] || "", System.os_time(:second)) != :ok ->
        send_json(conn, 401, %{error: "the signature is not valid"})

      not is_binary(conn.body_params["event_id"]) ->
        send_json(conn, 400, %{error: "event_id is required"})

      true ->
        outcome = Receiver.record(conn.body_params)

        send_json(conn, 200, %{
          received: conn.body_params["event_id"],
          duplicate: outcome == :duplicate
        })
    end
  end

  get "/webhooks" do
    send_json(conn, 200, Receiver.events())
  end

  get "/webhooks/page" do
    rows =
      Enum.map_join(Receiver.events(), "\n", fn event ->
        "<tr><td>#{event["received_at"]}</td><td>#{event["type"]}</td><td>#{event["country"]}</td>" <>
          "<td>#{event["application_id"]}</td><td>#{Enum.join(event["reason_codes"] || [], ", ")}</td></tr>"
      end)

    page = """
    <!doctype html><html><head><meta charset="utf-8"><title>Webhooks received</title>
    <style>body{font-family:sans-serif;margin:2rem}table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:.4rem .6rem;text-align:left}</style>
    </head><body><h1>Webhooks received</h1>
    <table><thead><tr><th>Received</th><th>Type</th><th>Country</th><th>Application</th><th>Reason codes</th></tr></thead>
    <tbody>#{rows}</tbody></table></body></html>
    """

    send_body(conn, 200, page, "text/html")
  end

  match _ do
    send_json(conn, 404, %{error: "not found"})
  end

  defp respond(:error, conn, _adapter, _request_id, _document),
    do: send_json(conn, 500, %{error: "the provider is unavailable"})

  # Longer than any client waits
  defp respond(:timeout, conn, _adapter, _request_id, _document) do
    Process.sleep(30_000)
    send_resp(conn, 504, "")
  end

  defp respond(:malformed, conn, adapter, _request_id, _document) do
    {body, type} = Providers.malformed(adapter)
    send_body(conn, 200, body, type)
  end

  defp respond(:ok, conn, "mx_webhook", request_id, document) do
    :ok = Mocks.Webhook.deliver_later(request_id, Providers.profile(document))
    send_json(conn, 202, %{request_id: request_id, status: "accepted"})
  end

  defp respond(:ok, conn, adapter, _request_id, document) do
    {body, type} = Providers.answer(adapter, Providers.profile(document))
    send_body(conn, 200, body, type)
  end

  defp send_json(conn, status, term),
    do: send_body(conn, status, Jason.encode!(term), "application/json")

  defp send_body(conn, status, body, type) do
    conn
    |> put_resp_content_type(type)
    |> send_resp(status, body)
  end
end
