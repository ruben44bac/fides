defmodule Fides.Orchestration.ConcurrentFlowTest do
  @moduledoc """
  People and agents work on the same applications at the same time, in random order:
  analysts and risk managers move them while the orchestrator's jobs run, twice over
  when two workers drain the same queues, with Mexico's webhooks arriving late and
  repeated, and new policy versions published in the middle. Whatever happens, the
  invariants of the life cycle and of the evidence hold.
  """

  # Seeds the same countries as other tests, and runs its commands in several processes
  use FidesWeb.ConnCase, async: false
  use ExUnitProperties
  use Oban.Testing, repo: Fides.Platform.Repo

  require Ash.Query
  require Ecto.Query

  alias Fides.Factory
  alias Fides.Notifications.Signature
  alias Fides.Origination
  alias Fides.Origination.CreditApplication
  alias Fides.Origination.Lifecycle
  alias Fides.Platform.AuditContext
  alias Fides.Platform.SystemActor

  @system SystemActor.new(:test)
  @countries ~w(ES MX)
  @queues ~w(orchestration intake banking_es banking_mx risk reevaluation webhooks notices)a
  @webhook_secret "fides test provider webhook secret"

  setup do
    Factory.reference_data()
    {admin, _secret} = Factory.staff_user(global_role: :admin)

    actors = %{
      analyst: %{
        "ES" => Factory.scoped_staff("ES", :analyst, admin),
        "MX" => Factory.scoped_staff("MX", :analyst, admin)
      },
      risk_manager: %{
        "ES" => Factory.scoped_staff("ES", :risk_manager, admin),
        "MX" => Factory.scoped_staff("MX", :risk_manager, admin)
      },
      second_risk_manager: %{
        "ES" => Factory.scoped_staff("ES", :risk_manager, admin),
        "MX" => Factory.scoped_staff("MX", :risk_manager, admin)
      }
    }

    for country <- @countries, do: Factory.policy_in_force(country, admin)

    AuditContext.run([actor: "staff_user:" <> admin.id, reason: "register the receiver"], fn ->
      Fides.Notifications.register_endpoint!(
        %{
          name: "Receiver",
          url: "http://receiver.test/events",
          secret: "a receiver secret of sixteen",
          events: [:info_requested, :approved, :rejected]
        },
        actor: admin
      )
    end)

    # Spain's provider answers at once; Mexico's accepts, and its webhook comes later
    Req.Test.stub(Fides.Banking.Client, fn conn ->
      if conn.request_path =~ "mx_webhook",
        do: Plug.Conn.send_resp(conn, 202, "{}"),
        else:
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, File.read!("test/fixtures/banking/es.json"))
    end)

    Req.Test.stub(Fides.Notifications.Deliver, &Plug.Conn.send_resp(&1, 200, ""))

    %{actors: actors}
  end

  # Holders are shared across the run, so one may apply again after a final state
  defp holders do
    for number <- 1..4, do: %{es: Factory.holder(number + 1_000_000), mx: mexican(number)}
  end

  defp mexican(number) do
    birth = Date.add(~D[1956-04-27], number)
    body = "HEGG" <> Calendar.strftime(birth, "%y%m%d") <> "MVZRRL0"

    %{
      Factory.mexican_holder()
      | document: body <> Integer.to_string(Fides.Identity.Documents.MX.check_digit(body)),
        birth_date: birth,
        email: "gloria.#{number}@example.com"
    }
  end

  defp amount, do: integer(500_000..7_000_000)
  defp income, do: integer(200_000..400_000)

  defp command do
    frequency([
      {4, tuple({constant(:submit), member_of(@countries), integer(0..3), amount(), income()})},
      {3, tuple({constant(:decide), integer(0..9), integer(0..99)})},
      {2, tuple({constant(:countersign), integer(0..9), boolean()})},
      {2, tuple({constant(:respond), integer(0..9), amount(), income()})},
      {2, tuple({constant(:reapply), integer(0..9), amount(), income()})},
      {1, tuple({constant(:cancel), integer(0..9)})},
      {3, tuple({constant(:webhook), integer(0..9), boolean()})},
      {1, tuple({constant(:publish), member_of(@countries), integer(1_000_000..4_000_000)})},
      {2, constant(:expire)}
    ])
  end

  property "people and agents working at once never break the life cycle or the evidence", ctx do
    check all rounds <-
                list_of(list_of(command(), min_length: 3, max_length: 8),
                  min_length: 3,
                  max_length: 5
                ),
              max_runs: 12 do
      holders = holders()

      Enum.reduce(rounds, %{ids: [], snapshot: %{}}, fn commands, run ->
        ids = run_round(commands, run.ids, holders, ctx)
        drain_twice()
        snapshot = snapshot(ids)
        check_invariants(run.snapshot, snapshot, ids)
        %{ids: ids, snapshot: snapshot}
      end)
      |> then(fn run -> check_at_rest(run.ids) end)
    end
  end

  test "a scripted run covers every way through, with two workers draining the queues at once",
       ctx do
    holders = holders()

    # Four Spanish applications and a Mexican one arrive together
    ids =
      run_round(
        [
          {:submit, "ES", 0, 1_000_000, 250_000},
          {:submit, "ES", 1, 6_000_000, 250_000},
          {:submit, "ES", 2, 2_500_000, 250_000},
          {:submit, "ES", 3, 3_000_000, 250_000},
          {:submit, "MX", 0, 10_000_000, 3_000_000}
        ],
        [],
        holders,
        ctx
      )

    drain_twice()
    first = snapshot(ids)
    check_invariants(%{}, first, ids)

    [small, large, medium, waiting, mexican] =
      Enum.map([1_000_000, 6_000_000, 2_500_000, 3_000_000, 10_000_000], &by_amount(first, &1))

    assert small.state == :approved
    assert Enum.map([large, medium, waiting], & &1.state) == [:in_review, :in_review, :in_review]
    assert mexican.state == :awaiting_bank_callback

    # People decide at once, while Mexico's provider times out
    at_once([
      fn -> person(ctx, :analyst, large, :pending_countersign) end,
      fn -> person(ctx, :analyst, medium, :info_requested) end,
      fn -> run_command(:expire, ids, holders, ctx) end
    ])

    drain_twice()
    second = snapshot(ids)
    check_invariants(first, second, ids)
    assert by_amount(second, 6_000_000).state == :pending_countersign
    assert by_amount(second, 2_500_000).state == :info_requested
    assert by_amount(second, 10_000_000).state == :provider_error

    # The countersignature and the answer with corrected terms, while Mexico retries
    at_once([
      fn -> person(ctx, :risk_manager, by_amount(second, 6_000_000), :approved) end,
      fn ->
        medium = by_amount(second, 2_500_000)

        as_person(ctx.actors.analyst["ES"], "respond", fn actor ->
          Origination.answer_information_request(
            medium,
            %{
              amount_minor: 1_500_000,
              monthly_income_minor: 250_000,
              expected_version: medium.lock_version
            },
            tenant: "ES",
            actor: actor
          )
        end)
      end,
      fn -> run_command(:expire, ids, holders, ctx) end
    ])

    drain_twice()
    third = snapshot(ids)
    check_invariants(second, third, ids)
    assert by_amount(third, 6_000_000).state == :approved
    assert %{state: :approved, revision: 2} = by_amount(third, 1_500_000)
    assert by_amount(third, 10_000_000).state == :awaiting_bank_callback

    # Mexico's webhook arrives twice, and Spain publishes a policy that approves what waited
    mexican = by_amount(third, 10_000_000)

    at_once([
      fn ->
        run_command(
          {:webhook, Enum.find_index(ids, &(&1 == mexican.id)), true},
          ids,
          holders,
          ctx
        )
      end,
      fn -> run_command({:publish, "ES", 7_000_000}, ids, holders, ctx) end
    ])

    drain_twice()
    fourth = snapshot(ids)
    check_invariants(third, fourth, ids)
    assert by_amount(fourth, 10_000_000).state == :approved
    assert by_amount(fourth, 3_000_000).state == :approved

    # Two calls were pending, the one that timed out and the retry: the answer to the
    # current one is applied, the late one is recorded and ignored, and each repeated
    # delivery was answered without a new event
    events = Fides.Notifications.list_inbound_events!(tenant: "MX", actor: @system)
    assert events |> Enum.map(& &1.result) |> Enum.sort() == [:applied, :ignored]

    reevaluated =
      Fides.Risk.list_decisions!(tenant: "ES", actor: @system)
      |> Enum.filter(&(&1.application_id == waiting.id))

    assert Enum.map(reevaluated, & &1.cause) == [:evaluation, :reevaluation]

    check_at_rest(ids)

    deliveries = Fides.Notifications.list_deliveries!(tenant: "ES", actor: @system)
    assert Enum.frequencies_by(deliveries, & &1.event_type) == %{approved: 4, info_requested: 1}

    assert [%{event_type: :approved}] =
             Fides.Notifications.list_deliveries!(tenant: "MX", actor: @system)
  end

  defp by_amount(snapshot, amount),
    do: snapshot |> Map.values() |> Enum.find(&(&1.amount_minor == amount))

  defp person(ctx, role, application, to) do
    as_person(ctx.actors[role][application.country_code], "decide", fn actor ->
      assert {:ok, _moved} = move(application, to, actor)
    end)
  end

  defp at_once(actions) do
    actions
    |> Task.async_stream(& &1.(), max_concurrency: 4, ordered: false, timeout: 60_000)
    |> Stream.run()
  end

  # Commands of one round run in several processes at once; their failures are expected
  defp run_round(commands, ids, holders, ctx) do
    created =
      commands
      |> Task.async_stream(&run_command(&1, ids, holders, ctx),
        max_concurrency: 4,
        ordered: false,
        timeout: 60_000
      )
      |> Enum.flat_map(fn {:ok, created} -> created end)
      |> Enum.filter(&is_binary/1)

    Enum.uniq(ids ++ created)
  end

  defp run_command({:submit, country, index, amount, income}, _ids, holders, ctx) do
    holder = holders |> Enum.at(index) |> Map.fetch!(if country == "ES", do: :es, else: :mx)

    submission =
      if country == "ES",
        do: Factory.submission(holder: holder),
        else: Factory.mexican_submission(holder: holder)

    as_person(ctx.actors.analyst[country], "submit", fn actor ->
      case Origination.submit_application(
             %{submission | amount_minor: amount, monthly_income_minor: income},
             tenant: country,
             actor: actor
           ) do
        {:ok, application} -> [application.id]
        {:error, _taken_or_invalid} -> []
      end
    end)
  end

  defp run_command({:decide, index, choice}, ids, _holders, ctx),
    do: with_application(ids, index, &decide(&1, choice, ctx))

  defp run_command({:countersign, index, approve?}, ids, _holders, ctx) do
    with_application(ids, index, fn application ->
      actor = ctx.actors.risk_manager[application.country_code]
      to = if approve?, do: :approved, else: :in_review
      as_person(actor, "countersign", fn actor -> move(application, to, actor) end)
    end)
  end

  defp run_command({:respond, index, amount, income}, ids, _holders, ctx) do
    with_application(ids, index, fn application ->
      as_person(ctx.actors.analyst[application.country_code], "respond", fn actor ->
        Origination.answer_information_request(
          application,
          %{
            amount_minor: amount,
            monthly_income_minor: income,
            expected_version: application.lock_version
          },
          tenant: application.country_code,
          actor: actor
        )
      end)
    end)
  end

  defp run_command({:reapply, index, amount, income}, ids, _holders, ctx),
    do: with_application(ids, index, &reapply(&1, amount, income, ctx))

  defp run_command({:cancel, index}, ids, _holders, ctx) do
    with_application(ids, index, fn application ->
      as_person(ctx.actors.analyst[application.country_code], "cancel", fn actor ->
        move(application, :cancelled, actor)
      end)
    end)
  end

  # Mexico's provider delivers the profile, sometimes twice, for whatever is waiting
  defp run_command({:webhook, index, duplicate?}, ids, _holders, _ctx),
    do: with_application(ids, index, &deliver_webhooks(&1, duplicate?))

  # Time passes: every scheduled move, a provider's timeout or a retry, comes due once
  defp run_command(:expire, _ids, _holders, _ctx) do
    for job <- scheduled(Fides.Orchestration.DelayedMove) do
      perform_job(Fides.Orchestration.DelayedMove, job.args)
    end

    []
  end

  defp run_command({:publish, country, review_above}, _ids, _holders, ctx) do
    {:ok, params} = Fides.Risk.default_params(country)

    params =
      if country == "ES", do: %{params | review_above_amount_minor: review_above}, else: params

    proposer = ctx.actors.risk_manager[country]

    AuditContext.run([actor: "staff_user:" <> proposer.id, reason: "new thresholds"], fn ->
      with {:ok, draft} <- Fides.Risk.propose_policy(params, tenant: country, actor: proposer) do
        Fides.Risk.publish_policy(draft,
          tenant: country,
          actor: ctx.actors.second_risk_manager[country]
        )
      end
    end)

    []
  end

  # The analyst makes one of the moves open to them
  defp decide(application, choice, ctx) do
    actor = ctx.actors.analyst[application.country_code]
    available = Fides.Origination.Moves.available(application, actor)

    if available != [] do
      to = Enum.at(available, rem(choice, length(available)))
      as_person(actor, "decide", fn actor -> move(application, to, actor) end)
    end
  end

  defp reapply(application, amount, income, ctx) do
    retry = %{
      previous_application_id: application.id,
      amount_minor: amount,
      monthly_income_minor: income,
      channel: :api,
      consent_text_version: "2026-10"
    }

    as_person(ctx.actors.analyst[application.country_code], "reapply", fn actor ->
      case Origination.reapply(retry, tenant: application.country_code, actor: actor) do
        {:ok, retried} -> [retried.id]
        {:error, _final_or_retried} -> []
      end
    end)
  end

  defp deliver_webhooks(%{country_code: "MX", state: :awaiting_bank_callback} = app, duplicate?) do
    for exchange <- pending_exchanges(app), _delivery <- 1..if(duplicate?, do: 2, else: 1) do
      deliver_webhook(exchange)
    end

    []
  end

  defp deliver_webhooks(_application, _duplicate?), do: []

  defp deliver_webhook(exchange) do
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

  defp as_person(actor, reason, fun) do
    AuditContext.run([actor: "staff_user:" <> actor.id, reason: reason], fn ->
      case fun.(actor) do
        created when is_list(created) -> created
        _result -> []
      end
    end)
  end

  defp move(application, to, actor) do
    Origination.transition_application(
      application,
      to,
      application.lock_version,
      %{reason: "random"},
      tenant: application.country_code,
      actor: actor
    )
  end

  defp with_application([], _index, _fun), do: []

  defp with_application(ids, index, fun) do
    id = Enum.at(ids, rem(index, length(ids)))
    {:ok, application} = Origination.find_application(id, actor: @system)
    fun.(application) || []
  end

  defp scheduled(worker) do
    Oban.Job
    |> Ecto.Query.where(
      [job],
      job.state == "scheduled" and job.worker == ^Oban.Worker.to_string(worker)
    )
    |> Fides.Platform.Repo.all()
  end

  defp pending_exchanges(application) do
    Fides.Banking.ProviderExchange
    |> Ash.Query.filter(application_id == ^application.id and status == :pending)
    |> Ash.read!(tenant: "MX", actor: @system)
  end

  # Two workers drain the queues with work at the same time; then one drains until the
  # jobs that others enqueued leave nothing behind
  defp drain_twice do
    1..2
    |> Task.async_stream(fn _worker -> Enum.each(busy_queues(), &drain/1) end, timeout: 60_000)
    |> Stream.run()

    drain_until_quiet(20)
  end

  defp drain_until_quiet(0), do: flunk("the queues never settled")

  defp drain_until_quiet(tries) do
    case busy_queues() do
      [] ->
        :ok

      queues ->
        Enum.each(queues, &drain/1)
        drain_until_quiet(tries - 1)
    end
  end

  # Scheduled jobs, the timeouts and retries, come due only when time passes
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

  defp snapshot(ids) do
    for id <- ids, into: %{} do
      {:ok, application} = Origination.find_application(id, actor: @system)
      {id, application}
    end
  end

  defp check_invariants(previous, current, ids) do
    for {id, before} <- previous do
      after_round = Map.fetch!(current, id)
      country = before.country_code

      if Lifecycle.final?(before.state) do
        assert {after_round.state, after_round.lock_version} ==
                 {before.state, before.lock_version},
               "#{id} left the final state #{before.state}"
      end

      if after_round.state != before.state do
        assert after_round.lock_version > before.lock_version

        assert reachable?(country, before.state, after_round.state),
               "#{country}: #{before.state} cannot reach #{after_round.state}"
      else
        assert after_round.lock_version >= before.lock_version
      end
    end

    for id <- ids, application = Map.fetch!(current, id) do
      assert_terms_match_revision(application)
    end

    assert_one_open_per_holder(ids)
    assert_one_advance_per_version(ids)
    assert_decisions_chain(ids)
  end

  # Every open state may be left for cancelled, so reachability follows the transitions
  defp reachable?(country, from, to) do
    edges = Lifecycle.transitions(country) |> Enum.group_by(& &1.from, & &1.to)
    walk(edges, [from], MapSet.new([from]), to)
  end

  defp walk(_edges, [], _seen, _to), do: false

  defp walk(edges, [state | rest], seen, to) do
    next = edges |> Map.get(state, []) |> Enum.reject(&MapSet.member?(seen, &1))

    if to in next,
      do: true,
      else: walk(edges, rest ++ next, Enum.reduce(next, seen, &MapSet.put(&2, &1)), to)
  end

  defp assert_terms_match_revision(application) do
    revisions =
      Fides.Origination.ApplicationRevision
      |> Ash.Query.filter(application_id == ^application.id)
      |> Ash.Query.sort(number: :asc)
      |> Ash.read!(tenant: application.country_code, actor: @system)

    assert Enum.map(revisions, & &1.number) == Enum.to_list(1..application.revision)
    current = List.last(revisions)

    assert {current.amount_minor, current.monthly_income_minor} ==
             {application.amount_minor, application.monthly_income_minor}
  end

  defp assert_one_open_per_holder(ids) do
    for country <- @countries do
      open =
        CreditApplication
        |> Ash.Query.filter(id in ^ids and state not in [:approved, :rejected, :cancelled])
        |> Ash.read!(tenant: country, actor: @system)

      holders = Enum.map(open, & &1.person_id)
      assert holders == Enum.uniq(holders), "a holder has two open applications in #{country}"
    end
  end

  defp assert_one_advance_per_version(ids) do
    for country <- @countries do
      runs = Fides.Orchestration.list_agent_runs!(tenant: country, actor: @system)

      advances =
        runs
        |> Enum.filter(&(&1.application_id in ids and &1.outcome == :advance))
        |> Enum.frequencies_by(&{&1.application_id, &1.lock_version, &1.agent})

      assert Enum.all?(advances, fn {_key, count} -> count == 1 end),
             "an agent advanced the same version twice: #{inspect(advances)}"
    end
  end

  # Each application's decisions form one chain: a first one, and each later one replacing the previous
  defp assert_decisions_chain(ids) do
    for country <- @countries do
      decisions =
        Fides.Risk.list_decisions!(tenant: country, actor: @system)
        |> Enum.filter(&(&1.application_id in ids))

      for {application_id, records} <- Enum.group_by(decisions, & &1.application_id) do
        firsts = Enum.count(records, &is_nil(&1.replaces_id))
        assert firsts == 1, "application #{application_id} has #{firsts} first decisions"
        replaced = records |> Enum.map(& &1.replaces_id) |> Enum.reject(&is_nil/1)
        assert replaced == Enum.uniq(replaced), "a decision was replaced twice"
      end
    end
  end

  # Once the queues are empty, every announced change was delivered and every notice sent
  defp check_at_rest(ids) do
    assert Fides.Platform.Repo.aggregate(Ecto.Query.where(Oban.Job, state: "available"), :count) ==
             0

    for country <- @countries do
      deliveries =
        Fides.Notifications.list_deliveries!(tenant: country, actor: @system)
        |> Enum.filter(&(&1.application_id in ids))

      assert Enum.all?(deliveries, &(&1.state == :delivered)),
             inspect(Enum.map(deliveries, & &1.state))

      notices =
        Fides.Notifications.list_notifications!(tenant: country, actor: @system)
        |> Enum.filter(&(&1.application_id in ids))

      assert Enum.all?(notices, &(&1.state == :sent)), inspect(Enum.map(notices, & &1.state))
    end
  end
end
