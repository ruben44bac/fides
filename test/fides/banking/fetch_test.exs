defmodule Fides.Banking.FetchTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use Fides.DataCase, async: false

  alias Fides.Banking
  alias Fides.Factory
  alias Fides.Origination
  alias Fides.Platform.AgentActor
  alias Fides.Platform.AuditContext
  alias Fides.Platform.SystemActor

  @banking AgentActor.new(:banking)
  @system SystemActor.new(:test)
  @holder %{document_type: "DNI", document: "12345678Z"}

  setup do
    Factory.reference_data()
    {admin, _secret} = Factory.staff_user(global_role: :admin)
    analyst = Factory.scoped_staff("ES", :analyst, admin)

    application =
      Factory.insert(fn ->
        Origination.submit_application!(
          Factory.submission(holder: Factory.holder() |> Map.merge(@holder)),
          tenant: "ES",
          actor: analyst
        )
      end)

    AuditContext.put(actor: "agent:banking", reason: "fetch bank data")
    %{application: application}
  end

  defp fetch(ctx, request_id \\ "req-1"),
    do: Banking.fetch_profile("ES", ctx.application.id, @holder, request_id, @banking)

  defp answer(body, status \\ 200, type \\ "application/json") do
    Req.Test.stub(Fides.Banking.Client, fn conn ->
      conn |> Plug.Conn.put_resp_content_type(type) |> Plug.Conn.send_resp(status, body)
    end)
  end

  defp exchanges, do: Banking.list_provider_exchanges!(tenant: "ES", actor: @system)
  defp profiles, do: Banking.list_bank_profiles!(tenant: "ES", actor: @system)

  test "keeps the provider's answer as a normalized, masked profile, and records the call", ctx do
    answer(File.read!("test/fixtures/banking/es.json"))

    assert {:ok, profile} = fetch(ctx)

    assert %{
             observed_income_minor: 250_000,
             total_debt_minor: 1_200_000,
             income_months: 6,
             score: 720,
             account_masked: "****1332",
             origin: :live
           } = profile

    assert [%{status: :ok, http_status: 200, attempt: 1, request_id: "req-1"} = exchange] =
             exchanges()

    assert profile.exchange_id == exchange.id
    assert profile.application_id == ctx.application.id
    assert profile.payload_hash == exchange.response_hash
    assert exchange.latency_ms >= 0
  end

  test "sends the document and the request id to the country's provider", ctx do
    Req.Test.stub(Fides.Banking.Client, fn conn ->
      send(self(), {:asked, conn.request_path, conn.body_params})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, File.read!("test/fixtures/banking/es.json"))
    end)

    {:ok, _profile} = fetch(ctx, "req-9")

    assert_received {:asked, "/providers/es_json/profiles", params}

    assert %{"request_id" => "req-9", "document_type" => "DNI", "document" => "12345678Z"} =
             params
  end

  test "a provider that answers later is recorded as pending", ctx do
    answer(~s({"status":"accepted"}), 202)

    assert {:accepted, "req-1"} = fetch(ctx)
    assert [%{status: :pending, http_status: 202}] = exchanges()
    assert profiles() == []
  end

  test "failures are recorded and keep nothing else: an error, a timeout and a malformed answer",
       ctx do
    answer("", 503)
    assert {:error, "the provider answered 503"} = fetch(ctx, "req-error")

    Req.Test.stub(Fides.Banking.Client, &Req.Test.transport_error(&1, :timeout))
    assert {:error, "the provider did not answer in time"} = fetch(ctx, "req-timeout")

    answer(~s({"cliente": {"iban": "ES91"}, "puntuacion": "alta"}))

    assert {:error, "the provider's answer is malformed: " <> _field} =
             fetch(ctx, "req-malformed")

    assert exchanges() |> Enum.map(&{&1.request_id, &1.status}) |> Enum.sort() == [
             {"req-error", :error},
             {"req-malformed", :error},
             {"req-timeout", :timeout}
           ]

    assert profiles() == []
  end

  test "a retried call reuses its request id and counts as the next attempt", ctx do
    answer("", 500)
    {:error, _reason} = fetch(ctx)
    {:error, _reason} = fetch(ctx)

    answer(File.read!("test/fixtures/banking/es.json"))
    {:ok, _profile} = fetch(ctx)

    assert exchanges() |> Enum.map(& &1.attempt) |> Enum.sort() == [1, 2, 3]
    assert exchanges() |> Enum.map(& &1.request_hash) |> Enum.uniq() |> length() == 1
  end

  test "neither the document nor the provider's raw answer is stored", ctx do
    body = File.read!("test/fixtures/banking/es.json")
    answer(body)
    {:ok, _profile} = fetch(ctx)

    for table <- ["provider_exchanges", "bank_profiles"] do
      %{rows: rows} = Repo.query!("SELECT * FROM #{table}")
      text = inspect(rows)
      refute text =~ "12345678Z"
      refute text =~ "ES91 2100"
      refute text =~ "deuda_total_centimos"
    end
  end
end
