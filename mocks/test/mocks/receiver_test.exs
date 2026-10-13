defmodule Mocks.ReceiverTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Mocks.Router

  @opts Router.init([])
  @secret "fides development webhook receiver secret"

  setup do
    Mocks.Receiver.clear()
    System.delete_env("MOCKS_RECEIVER_DOWN")
    :ok
  end

  defp event(id),
    do:
      Jason.encode!(%{
        event_id: id,
        type: "application.approved",
        country: "ES",
        application_id: "app-1",
        reason_codes: []
      })

  defp deliver(body, signature) do
    :post
    |> conn("/webhooks", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-signature", signature)
    |> Router.call(@opts)
  end

  test "keeps a signed event once, however many times it is delivered" do
    body = event("evt_1")
    signature = Mocks.Webhook.sign(@secret, body, System.os_time(:second))

    assert %{status: 200} = first = deliver(body, signature)
    assert %{"received" => "evt_1", "duplicate" => false} = Jason.decode!(first.resp_body)

    assert %{status: 200} = again = deliver(body, signature)
    assert %{"duplicate" => true} = Jason.decode!(again.resp_body)

    assert [%{"event_id" => "evt_1", "received_at" => _}] = Mocks.Receiver.events()

    listed = :get |> conn("/webhooks") |> Router.call(@opts)
    assert [%{"event_id" => "evt_1"}] = Jason.decode!(listed.resp_body)

    page = :get |> conn("/webhooks/page") |> Router.call(@opts)
    assert page.status == 200 and page.resp_body =~ "application.approved"
  end

  test "refuses a bad or old signature" do
    body = event("evt_2")

    assert %{status: 401} =
             deliver(body, Mocks.Webhook.sign("another secret", body, System.os_time(:second)))

    assert %{status: 401} =
             deliver(body, Mocks.Webhook.sign(@secret, body, System.os_time(:second) - 400))

    assert %{status: 401} = deliver(body, "nonsense")
    assert Mocks.Receiver.events() == []
  end

  test "can be down for a demo" do
    System.put_env("MOCKS_RECEIVER_DOWN", "1")
    body = event("evt_3")

    assert %{status: 503} =
             deliver(body, Mocks.Webhook.sign(@secret, body, System.os_time(:second)))

    assert Mocks.Receiver.events() == []
  end
end
