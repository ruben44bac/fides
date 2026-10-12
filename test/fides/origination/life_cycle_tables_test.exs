defmodule Fides.Origination.LifeCycleTablesTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use Fides.DataCase, async: false

  alias Fides.Factory
  alias Fides.Origination
  alias Fides.Origination.Seeds
  alias Fides.Platform.SystemActor

  @system SystemActor.new(:orchestrator)

  setup do
    Factory.reference_data()
    {admin, _secret} = Factory.staff_user(global_role: :admin)

    %{analyst: Factory.scoped_staff("ES", :analyst, admin)}
  end

  defp submit(ctx) do
    Factory.insert(fn ->
      Origination.submit_application!(Factory.submission(), tenant: "ES", actor: ctx.analyst)
    end)
  end

  # The rows as they are, so a seed that rewrote them would show
  defp tables(country) do
    opts = [tenant: country, actor: @system]

    %{
      states:
        opts
        |> Origination.list_lifecycle_states!()
        |> Enum.map(&{&1.state, &1.inserted_at})
        |> Enum.sort(),
      transitions:
        opts
        |> Origination.list_lifecycle_transitions!()
        |> Enum.map(&{&1.from_state, &1.to_state, &1.inserted_at})
        |> Enum.sort()
    }
  end

  defp graph(country) do
    %{states: states, transitions: transitions} = tables(country)

    %{
      states: states |> Enum.map(&elem(&1, 0)) |> Enum.sort(),
      transitions: transitions |> Enum.map(fn {from, to, _at} -> {from, to} end) |> Enum.sort()
    }
  end

  defp sorted(graph),
    do: %{states: Enum.sort(graph.states), transitions: Enum.sort(graph.transitions)}

  defp without(graph, state) do
    %{
      states: graph.states -- [state],
      transitions: Enum.reject(graph.transitions, fn {from, to} -> state in [from, to] end)
    }
  end

  # Runs SQL in a savepoint, so a refused statement leaves the test's transaction usable
  defp raw(statements),
    do: Factory.insert(fn -> Repo.transaction(fn -> query!(statements) end) end)

  defp query!(statements),
    do: Enum.each(statements, fn {sql, params} -> Repo.query!(sql, params) end)

  defp dump(id), do: Ecto.UUID.dump!(id)

  describe "the seeds" do
    test "write each country's life cycle as the code declares it, and again change nothing" do
      for {country, graph} <- Seeds.graphs() do
        assert graph(country) == sorted(graph), country
      end

      before = Map.new(Seeds.graphs(), fn {country, _graph} -> {country, tables(country)} end)
      Factory.insert(fn -> Seeds.run() end)

      for {country, rows} <- before, do: assert(tables(country) == rows, country)
    end

    test "remove the states and transitions the code no longer declares" do
      graphs = Map.update!(Seeds.graphs(), "CO", &without(&1, :provider_error))
      Factory.insert(fn -> Seeds.run(graphs) end)

      assert graph("CO") == sorted(graphs["CO"])
      refute :provider_error in graph("CO").states
      assert :provider_error in graph("BR").states
    end

    test "fail without changing anything while a state to remove holds applications", ctx do
      application = submit(ctx)

      Factory.insert(fn ->
        Origination.transition_application!(application, :validating, 1,
          tenant: "ES",
          actor: @system
        )
      end)

      before = tables("ES")
      graphs = Map.update!(Seeds.graphs(), "ES", &without(&1, :validating))

      assert_raise RuntimeError, ~r/still hold applications: ES validating/, fn ->
        Factory.insert(fn -> Seeds.run(graphs) end)
      end

      assert tables("ES") == before
    end
  end

  describe "the database" do
    test "moves an application only along its country's life cycle", ctx do
      application = submit(ctx)
      update = "UPDATE credit_applications SET state = $2 WHERE id = $1"

      # Skipping steps, or into a state only Mexico has
      for state <- ["approved", "awaiting_bank_callback"] do
        assert_raise Postgrex.Error, ~r/credit_applications_transition/, fn ->
          raw([{update, [dump(application.id), state]}])
        end
      end

      raw([{update, [dump(application.id), "validating"]}])
    end

    test "creates an application only in submitted", ctx do
      application = submit(ctx)

      assert_raise Postgrex.Error, ~r/credit_applications_starts_submitted/, fn ->
        raw([
          {"""
           INSERT INTO credit_applications (country_code, person_id, currency, amount_minor,
             monthly_income_minor, state, channel, submitted_at)
           VALUES ('ES', $1, 'EUR', 1, 1, 'approved', 'api', now())
           """, [dump(application.person_id)]}
        ])
      end
    end

    test "keeps a state while an application is in it", ctx do
      submit(ctx)

      assert_raise Postgrex.Error, ~r/credit_applications_state_fkey/, fn ->
        raw([
          {"""
           DELETE FROM lifecycle_transitions
           WHERE country_code = 'ES' AND 'submitted' IN (from_state, to_state)
           """, []},
          {"DELETE FROM lifecycle_states WHERE country_code = 'ES' AND state = 'submitted'", []}
        ])
      end
    end

    test "refuses a move missing from its tables, even when the code allows it", ctx do
      application = submit(ctx)

      raw([
        {"""
         DELETE FROM lifecycle_transitions
         WHERE country_code = 'ES' AND from_state = 'submitted' AND to_state = 'validating'
         """, []}
      ])

      assert {:error, error} =
               Factory.insert(fn ->
                 Origination.transition_application(application, :validating, 1,
                   tenant: "ES",
                   actor: @system
                 )
               end)

      assert Exception.message(error) =~ "is not a transition of the country's life cycle"
    end
  end
end
