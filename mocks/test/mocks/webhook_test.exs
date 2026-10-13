defmodule Mocks.WebhookTest do
  use ExUnit.Case, async: true

  alias Mocks.Webhook

  test "signs the body as Fides verifies it" do
    body = ~s({"event_id":"evt_1"})
    signature = Webhook.sign("secret", body, 1_700_000_000)

    assert "t=1700000000,v1=" <> digest = signature

    assert digest ==
             :hmac
             |> :crypto.mac(:sha256, "secret", "1700000000.#{body}")
             |> Base.encode16(case: :lower)
  end

  test "delivers the signed event to Fides" do
    Req.Test.stub(Mocks.Webhook, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        self(),
        {:delivered, conn.request_path, Plug.Conn.get_req_header(conn, "x-signature"), body}
      )

      Plug.Conn.send_resp(conn, 202, "")
    end)

    body =
      Mocks.Providers.mexican_event(
        "evt_1",
        "req-1",
        1,
        Mocks.Providers.profile("HEGG560427MVZRRL04")
      )

    assert :ok = Webhook.deliver(body, 1_700_000_000)

    assert_received {:delivered, "/webhooks/providers/MX", ["t=1700000000,v1=" <> _], ^body}
    assert %{"perfil" => %{"ingreso_mensual" => income}} = Jason.decode!(body)
    assert is_number(income)
  end
end
