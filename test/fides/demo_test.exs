defmodule Fides.DemoTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use FidesWeb.ConnCase, async: false

  alias Fides.Accounts.Demo, as: Staff
  alias Fides.Factory
  alias Fides.Notifications.Signature
  alias Fides.Origination
  alias Fides.Platform.SystemActor

  require Ecto.Query

  @system SystemActor.new(:orchestrator)
  @queues ~w(orchestration intake banking_es banking_mx risk webhooks notices ai)a
  @webhook_secret "fides test provider webhook secret"

  setup do
    Factory.reference_data()
    {admin, _secret} = Factory.staff_user(global_role: :admin)
    Factory.policy_in_force("ES", admin)
    Factory.policy_in_force("MX", admin)

    # The demo's own staff, as the seeds create them
    for {handle, country} <- [{"analyst_es", "ES"}, {"analyst_mx", "MX"}] do
      staff = Staff.user(handle)

      {user, _secret} =
        Factory.staff_user(
          email: staff.email,
          password: Staff.password(),
          totp_secret: Staff.totp_secret(handle)
        )

      Factory.scope(user, country, :analyst, admin)
    end

    # The demo's requests reach the endpoint in this process; Spain's provider answers
    # at once, Mexico's accepts and its webhook comes later
    Req.Test.stub(Fides.Demo, &FidesWeb.Endpoint.call(&1, FidesWeb.Endpoint.init([])))

    Req.Test.stub(Fides.Banking.Client, fn conn ->
      if conn.request_path =~ "mx_webhook",
        do: Plug.Conn.send_resp(conn, 202, "{}"),
        else:
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, File.read!("test/fixtures/banking/es.json"))
    end)

    Req.Test.stub(Fides.Notifications.Deliver, &Plug.Conn.send_resp(&1, 200, ""))

    {:ok, log} = Agent.start_link(fn -> [] end)
    %{log: log}
  end

  defp lines(log), do: log |> Agent.get(& &1) |> Enum.reverse()

  # What the workers and Mexico's provider would do meanwhile: one pass over the queues
  # with work, so every state shows, and a signed webhook for every accepted request
  defp work do
    deliver_webhooks()
    Enum.each(busy_queues(), &drain/1)
  end

  # Scheduled jobs, the timeouts, come due only when time passes
  defp busy_queues do
    Oban.Job
    |> Ecto.Query.where([job], job.state == "available")
    |> Ecto.Query.select([job], job.queue)
    |> Ecto.Query.distinct(true)
    |> Fides.Platform.Repo.all()
    |> Enum.map(&String.to_existing_atom/1)
    |> Enum.filter(&(&1 in @queues))
  end

  defp drain(queue) do
    result =
      Oban.drain_queue(
        queue: queue,
        with_recursion: true,
        with_scheduled: false,
        with_safety: false
      )

    assert %{failure: 0, discard: 0} = Map.take(result, [:failure, :discard]),
           "#{queue}: #{inspect(result)}"
  end

  defp deliver_webhooks do
    for application <- Origination.list_applications!(tenant: "MX", actor: @system),
        application.state == :awaiting_bank_callback,
        {:ok, exchanges} = Fides.Banking.exchanges("MX", application.id, @system),
        exchange <- exchanges,
        exchange.status == :pending do
      body =
        "test/fixtures/banking/mx.json"
        |> File.read!()
        |> Jason.decode!()
        |> Map.merge(%{
          "request_id" => exchange.request_id,
          "event_id" => "evt_" <> exchange.request_id
        })
        |> Jason.encode!()

      response =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header(
          "x-signature",
          Signature.sign(@webhook_secret, body, System.os_time(:second))
        )
        |> post("/webhooks/providers/MX", body)

      assert response.status == 202
    end
  end

  test "runs the three scenarios to their ends, following each one state by state", ctx do
    assert :ok =
             Fides.Demo.run(
               url: "http://fides.test",
               log: fn line -> Agent.update(ctx.log, &[line | &1]) end,
               tick: &work/0,
               interval: 0,
               timeout: 30_000,
               seed: 4_242
             )

    text = ctx.log |> lines() |> Enum.join("\n")

    assert text =~ "1/3  Approved on its own — Spain, EUR 10,000.00 at EUR 2,500.00 a month"
    assert text =~ "2/3  Approved after review — Spain, EUR 25,000.00"
    assert text =~ "3/3  Rejected by the policy — Mexico, MXN 500,000.00 at MXN 50,000.00 a month"
    assert text =~ "→ awaiting bank data"
    assert text =~ "→ in review"
    assert text =~ "the analyst decides: approved"
    assert text =~ "→ awaiting bank callback"
    assert text =~ "✓ approved in"
    assert text =~ "✓ rejected in"
    assert text =~ "All three scenarios ended as expected"

    spain = Origination.list_applications!(tenant: "ES", actor: @system)
    assert spain |> Enum.map(& &1.state) |> Enum.sort() == [:approved, :approved]
    assert spain |> Enum.map(& &1.person_id) |> Enum.uniq() |> length() == 2

    assert [%{state: :rejected, revision: 1}] =
             Origination.list_applications!(tenant: "MX", actor: @system)
  end

  test "explains an app that cannot be reached, or a sign-in refused", ctx do
    log = fn line -> Agent.update(ctx.log, &[line | &1]) end

    Req.Test.stub(Fides.Demo, &Req.Test.transport_error(&1, :econnrefused))
    assert {:error, reason} = Fides.Demo.run(url: "http://fides.test", log: log, interval: 0)
    assert reason =~ "Is the app running?"

    Req.Test.stub(Fides.Demo, &Plug.Conn.send_resp(&1, 401, "{}"))
    assert {:error, reason} = Fides.Demo.run(url: "http://fides.test", log: log, interval: 0)
    assert reason =~ "A code works once"
  end
end
