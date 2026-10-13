defmodule Mocks.RouterTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Mocks.Router

  @opts Router.init([])

  defp ask(adapter, document, headers \\ []) do
    conn =
      :post
      |> conn(
        "/providers/#{adapter}/profiles",
        Jason.encode!(%{request_id: "req-1", document_type: "DNI", document: document})
      )
      |> put_req_header("content-type", "application/json")

    headers
    |> Enum.reduce(conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
    |> Router.call(@opts)
  end

  test "each provider answers in its own format, the same for the same document" do
    es = ask("es_json", "12345678Z")
    assert es.status == 200

    assert %{"cliente" => %{"ingresos" => %{"mensual_centimos" => cents}}, "puntuacion" => _} =
             Jason.decode!(es.resp_body)

    assert cents ==
             Jason.decode!(ask("es_json", "12345678Z").resp_body)["cliente"]["ingresos"][
               "mensual_centimos"
             ]

    assert %{"rendimento_mensal" => amount} = Jason.decode!(ask("pt_json", "123456789").resp_body)
    assert amount =~ ~r/^\d{1,3}(\.\d{3})*,\d{2}$/

    it = ask("it_xml", "RSSMRA85M01H501Z")
    assert get_resp_header(it, "content-type") |> List.first() =~ "application/xml"
    assert it.resp_body =~ "<reddito_mensile valuta=\"EUR\">"

    assert %{"ingreso_mensual_pesos" => pesos, "deuda_total_pesos" => _} =
             Jason.decode!(ask("co_json", "1234567").resp_body)

    assert rem(pesos, 1_800) == 0

    assert %{"rendaMensalCentavos" => _, "score" => score} =
             Jason.decode!(ask("br_json", "52998224725").resp_body)

    assert score in 0..1000
  end

  test "Mexico accepts the request, and delivers the profile later, signed" do
    test = self()

    Req.Test.stub(Mocks.Webhook, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:delivered, Plug.Conn.get_req_header(conn, "x-signature"), Jason.decode!(body)})
      Plug.Conn.send_resp(conn, 202, "")
    end)

    System.put_env("MOCKS_WEBHOOK_DELAY_MS", "0")
    on_exit(fn -> System.delete_env("MOCKS_WEBHOOK_DELAY_MS") end)

    mx = ask("mx_webhook", "HEGG560427MVZRRL04")
    assert mx.status == 202
    assert %{"status" => "accepted", "request_id" => "req-1"} = Jason.decode!(mx.resp_body)

    assert_receive {:delivered, ["t=" <> _],
                    %{"request_id" => "req-1", "perfil" => %{"clabe" => _}}}
  end

  test "a scenario can be forced for one call" do
    assert ask("es_json", "12345678Z", [{"x-mock-scenario", "error"}]).status == 500

    malformed = ask("es_json", "12345678Z", [{"x-mock-scenario", "malformed"}])
    assert malformed.status == 200
    assert %{"unexpected" => _} = Jason.decode!(malformed.resp_body)
  end

  test "unknown providers and incomplete requests are refused" do
    assert ask("ar_json", "12345678").status == 404

    conn =
      :post
      |> conn("/providers/es_json/profiles", Jason.encode!(%{document_type: "DNI"}))
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    assert conn.status == 400
  end
end
