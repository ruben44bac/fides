defmodule Fides.Origination.InvariantsTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use Fides.DataCase, async: false
  use ExUnitProperties

  require Ash.Query

  alias Fides.Factory
  alias Fides.Origination
  alias Fides.Origination.ApplicationRevision
  alias Fides.Origination.CreditApplication
  alias Fides.Origination.Lifecycle
  alias Fides.Platform.AuditContext
  alias Fides.Platform.SystemActor

  @actor_kinds [:system, :analyst, :risk_manager]

  setup do
    Factory.reference_data()
    {admin, _secret} = Factory.staff_user(global_role: :admin)
    policy = Factory.policy_in_force("ES", admin)
    AuditContext.put(actor: "system:test", reason: "random commands")

    %{
      policy: policy,
      actors: %{
        system: SystemActor.new(:orchestrator),
        analyst: Factory.scoped_staff("ES", :analyst, admin),
        risk_manager: Factory.scoped_staff("ES", :risk_manager, admin)
      }
    }
  end

  # Advancing makes one of the moves the life cycle allows to anyone, so sequences reach
  # every state; the other commands also try what should fail
  defp command do
    frequency([
      {2, tuple({constant(:submit), integer(0..2), amount(), amount()})},
      {12, tuple({constant(:advance), integer(0..9), integer(0..99), amount(), amount()})},
      {2,
       tuple(
         {constant(:move), integer(0..9), member_of(Lifecycle.states()), member_of(@actor_kinds)}
       )},
      {1, tuple({constant(:respond), integer(0..9), amount(), amount()})},
      {2, tuple({constant(:reapply), integer(0..9), amount(), amount()})},
      {1, tuple({constant(:reevaluate), integer(0..9)})},
      {1, tuple({constant(:stale_move), integer(0..9), member_of(Lifecycle.states())})}
    ])
  end

  defp amount, do: integer(1..10_000_000)

  property "random sequences of commands never break the life cycle's invariants", ctx do
    check all commands <- list_of(command(), min_length: 30, max_length: 80), max_runs: 60 do
      holders = for _holder <- 1..3, do: Factory.holder()
      initial = %{applications: [], finals: %{}, versions: %{}, seen: MapSet.new()}

      Enum.reduce(commands, initial, fn command, state ->
        state
        |> run(command, holders, ctx)
        |> check_invariants()
      end)
    end
  end

  defp run(state, {:submit, holder, amount, income}, holders, ctx) do
    submission =
      Factory.submission(
        holder: Enum.at(holders, holder),
        amount_minor: amount,
        monthly_income_minor: income
      )

    case Origination.submit_application(submission, tenant: "ES", actor: ctx.actors.analyst) do
      {:ok, application} -> %{state | applications: state.applications ++ [application.id]}
      {:error, _error} -> state
    end
  end

  defp run(state, {:advance, index, choice, amount, income}, _holders, ctx) do
    with_application(state, index, fn application ->
      case options(state, application, choice) do
        [] ->
          state

        options ->
          advance(
            state,
            application,
            Enum.at(options, rem(choice, length(options))),
            {amount, income},
            ctx
          )
      end
    end)
  end

  defp run(state, {:move, index, to, kind}, _holders, ctx) do
    with_application(state, index, &move(state, &1, to, kind, ctx))
  end

  defp run(state, {:respond, index, amount, income}, _holders, ctx) do
    with_application(state, index, &answer(state, &1, amount, income, ctx))
  end

  defp run(state, {:reapply, index, amount, income}, _holders, ctx) do
    with_application(state, index, fn application ->
      retry = %{
        previous_application_id: application.id,
        amount_minor: amount,
        monthly_income_minor: income,
        channel: :api,
        consent_text_version: "2026-10"
      }

      case Origination.reapply(retry, tenant: "ES", actor: ctx.actors.analyst) do
        {:ok, retried} -> %{state | applications: state.applications ++ [retried.id]}
        {:error, _error} -> state
      end
    end)
  end

  defp run(state, {:reevaluate, index}, _holders, ctx) do
    with_application(state, index, fn application ->
      Origination.reevaluate_application(application, "new policy", application.lock_version,
        tenant: "ES",
        actor: ctx.actors.system
      )

      state
    end)
  end

  # A command with a version the application has left always fails
  defp run(state, {:stale_move, index, to}, _holders, ctx) do
    with_application(state, index, fn application ->
      for kind <- @actor_kinds do
        assert {:error, _error} =
                 Origination.transition_application(
                   application,
                   to,
                   application.lock_version - 1,
                   %{reason: "stale"},
                   tenant: "ES",
                   actor: Map.fetch!(ctx.actors, kind)
                 )
      end

      state
    end)
  end

  # Moves to states this sequence has not seen yet come first, and cancelling one time
  # in ten, so sequences get deep into the life cycle
  defp options(state, application, choice) do
    context = %{
      amount_minor: application.amount_minor,
      countersign_above_minor: threshold(application)
    }

    {cancels, moves} =
      for(
        kind <- @actor_kinds,
        to <- Lifecycle.available("ES", application.state, kind, context),
        do: {kind, to}
      )
      |> Enum.split_with(&match?({_kind, :cancelled}, &1))

    novel = Enum.reject(moves, fn {_kind, to} -> to in state.seen end)

    cond do
      choice < 60 and novel != [] -> novel
      choice < 90 and moves != [] -> moves
      true -> cancels
    end
  end

  # Back to validation from info_requested is an answer, with new terms
  defp advance(state, %{state: :info_requested} = application, {_kind, :validating}, terms, ctx) do
    {amount, income} = terms
    answer(state, application, amount, income, ctx)
  end

  defp advance(state, application, {kind, to}, _terms, ctx),
    do: move(state, application, to, kind, ctx)

  defp answer(state, application, amount, income, ctx) do
    terms = %{
      amount_minor: amount,
      monthly_income_minor: income,
      expected_version: application.lock_version
    }

    Origination.answer_information_request(application, terms,
      tenant: "ES",
      actor: ctx.actors.analyst
    )

    state
  end

  defp move(state, application, to, kind, ctx) do
    extra =
      if kind == :system and application.state == :evaluating,
        do: %{policy_version_id: ctx.policy.id},
        else: %{}

    Origination.transition_application(
      application,
      to,
      application.lock_version,
      Map.put(extra, :reason, "random move"),
      tenant: "ES",
      actor: Map.fetch!(ctx.actors, kind)
    )

    state
  end

  defp with_application(%{applications: []} = state, _index, _fun), do: state

  defp with_application(state, index, fun) do
    id = Enum.at(state.applications, rem(index, length(state.applications)))
    fun.(Ash.get!(CreditApplication, id, tenant: "ES", authorize?: false))
  end

  defp threshold(application),
    do: Fides.Risk.countersign_threshold("ES", application.policy_version_id)

  defp check_invariants(%{applications: []} = state), do: state

  defp check_invariants(state) do
    applications =
      CreditApplication
      |> Ash.Query.filter(id in ^state.applications)
      |> Ash.read!(tenant: "ES", authorize?: false)

    revisions =
      ApplicationRevision
      |> Ash.Query.filter(application_id in ^state.applications)
      |> Ash.read!(tenant: "ES", authorize?: false)
      |> Enum.group_by(& &1.application_id)

    # At most one application in progress per holder
    for {_person, open} <-
          Enum.group_by(Enum.reject(applications, &Lifecycle.final?(&1.state)), & &1.person_id) do
      assert length(open) == 1
    end

    for application <- applications do
      # Revisions run from 1 without gaps, and the application carries the current one
      numbered = Enum.sort_by(Map.fetch!(revisions, application.id), & &1.number)
      assert Enum.map(numbered, & &1.number) == Enum.to_list(1..application.revision)
      current = List.last(numbered)

      assert {current.amount_minor, current.monthly_income_minor} ==
               {application.amount_minor, application.monthly_income_minor}

      # A final application never changes, and the version never goes back
      final = state.finals[application.id]
      if final, do: assert(snapshot(application) == final)
      assert application.lock_version >= Map.get(state.versions, application.id, 1)

      # A retry points to an application of the same holder, retried only once
      previous = Enum.find(applications, &(&1.id == application.previous_application_id))

      if previous do
        assert previous.person_id == application.person_id
        assert Lifecycle.final?(previous.state)
      end
    end

    retried = applications |> Enum.map(& &1.previous_application_id) |> Enum.reject(&is_nil/1)
    assert retried == Enum.uniq(retried)

    %{
      state
      | finals:
          Map.new(for a <- applications, Lifecycle.final?(a.state), do: {a.id, snapshot(a)}),
        versions: Map.new(applications, &{&1.id, &1.lock_version}),
        seen: Enum.into(applications, state.seen, & &1.state)
    }
  end

  defp snapshot(application),
    do:
      Map.take(application, [
        :state,
        :lock_version,
        :revision,
        :amount_minor,
        :monthly_income_minor
      ])
end
