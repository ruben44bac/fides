defmodule Fides.Origination.LifecycleTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Fides.Origination.Lifecycle

  @humans [:applicant, :analyst, :risk_manager]
  @within %{amount_minor: 4_000, countersign_above_minor: 5_000}
  @above %{amount_minor: 6_000, countersign_above_minor: 5_000}
  @countersign ~w(ES PT IT)
  @effect_kinds [
    :transition,
    :agent,
    :timeout,
    :retry,
    :queue,
    :capability,
    :webhook,
    :notice,
    :alert
  ]

  test "a transition the life cycle does not allow fails with the valid ones" do
    assert Lifecycle.transition("MX", :submitted, :approved, :system) ==
             {:error, {:not_allowed, [:validating]}}

    assert Lifecycle.transition("MX", :submitted, :validating, :system) == {:ok, :validating}
  end

  test "a person never performs a system transition, and the system never a person's" do
    for country <- Lifecycle.countries(), transition <- Lifecycle.transitions(country) do
      humans = Enum.filter(transition.actors, &(&1 in @humans))
      assert humans == [] or :system not in transition.actors

      for actor <- Lifecycle.actors() -- transition.actors do
        refute transition.to in Lifecycle.available(country, transition.from, actor, @above)
        refute transition.to in Lifecycle.available(country, transition.from, actor, @within)
      end
    end
  end

  test "final states have no way out" do
    for country <- Lifecycle.countries(),
        state <- Lifecycle.final_states(),
        actor <- Lifecycle.actors(),
        target <- Lifecycle.states() do
      assert Lifecycle.transition(country, state, target, actor, @above) ==
               {:error, {:final_state, state}}
    end
  end

  test "every open state can be cancelled by the applicant and by an analyst" do
    for country <- Lifecycle.countries(),
        state <- Lifecycle.states(country) -- Lifecycle.final_states(),
        actor <- [:applicant, :analyst] do
      assert Lifecycle.transition(country, state, :cancelled, actor) == {:ok, :cancelled}
    end
  end

  test "evaluation follows the bank data, and returns from review only by the system" do
    for country <- Lifecycle.countries() do
      into_evaluating =
        for %{to: :evaluating} = transition <- Lifecycle.transitions(country),
            do: {transition.from, transition.actors}

      bank_data =
        if Lifecycle.bank_data(country) == :sync,
          do: :awaiting_bank_data,
          else: :awaiting_bank_callback

      assert Enum.sort(into_evaluating) ==
               Enum.sort([{bank_data, [:system]}, in_review: [:system]])
    end
  end

  describe "each country" do
    test "has only the states of its variant" do
      for country <- Lifecycle.countries() do
        states = Lifecycle.states(country)

        assert :awaiting_bank_callback in states == (Lifecycle.bank_data(country) == :async)
        assert :pending_countersign in states == Lifecycle.countersign?(country)
      end

      assert Enum.map(Lifecycle.countries(), &{&1, Lifecycle.bank_data(&1)}) == [
               {"ES", :sync},
               {"PT", :sync},
               {"IT", :sync},
               {"MX", :async},
               {"CO", :sync},
               {"BR", :sync}
             ]

      assert Enum.filter(Lifecycle.countries(), &Lifecycle.countersign?/1) == @countersign
    end

    test "refuses a move into a state its variant does not have" do
      assert {:error, {:not_allowed, available}} =
               Lifecycle.transition("ES", :awaiting_bank_data, :awaiting_bank_callback, :system)

      assert :evaluating in available

      assert {:error, {:not_allowed, _available}} =
               Lifecycle.transition("MX", :in_review, :pending_countersign, :analyst, @above)
    end

    test "states its effects on entering each of its states, and no others" do
      for country <- Lifecycle.countries() do
        effects = Lifecycle.effects(country)
        assert Enum.sort(Map.keys(effects)) == Enum.sort(Lifecycle.states(country)), country

        for {_state, list} <- effects, {kind, name} <- list do
          assert kind in @effect_kinds
          assert is_atom(name)
        end
      end

      assert Lifecycle.effects("MX").awaiting_bank_callback == [timeout: :bank_callback]
      assert Lifecycle.effects("ES").pending_countersign == [queue: :countersign]
      assert Lifecycle.effects("CO").evaluating == [agent: :risk]
    end

    test "is one Fides operates in" do
      assert_raise ArgumentError, ~r/"FR" has no life cycle/, fn ->
        Lifecycle.transitions("FR")
      end
    end
  end

  test "in Mexico the bank data arrives later: the application waits for the provider's webhook" do
    assert Lifecycle.available("MX", :awaiting_bank_data, :system) == [
             :awaiting_bank_callback,
             :provider_error
           ]

    assert Lifecycle.available("MX", :awaiting_bank_callback, :system) == [
             :evaluating,
             :provider_error
           ]

    assert Lifecycle.available("ES", :awaiting_bank_data, :system) == [
             :evaluating,
             :provider_error
           ]
  end

  describe "an analyst's approval" do
    test "above the countersign threshold needs a risk manager, where the country has one" do
      for country <- @countersign do
        assert :approved in Lifecycle.available(country, :in_review, :analyst, @within)
        refute :pending_countersign in Lifecycle.available(country, :in_review, :analyst, @within)

        assert :pending_countersign in Lifecycle.available(country, :in_review, :analyst, @above)
        refute :approved in Lifecycle.available(country, :in_review, :analyst, @above)

        assert Lifecycle.available(country, :pending_countersign, :risk_manager) == [
                 :approved,
                 :in_review
               ]

        assert Lifecycle.available(country, :pending_countersign, :analyst) == [:cancelled]
      end
    end

    test "is final with any amount where the country has no countersignature" do
      for country <- Lifecycle.countries() -- @countersign, context <- [%{}, @within, @above] do
        assert Lifecycle.available(country, :in_review, :analyst, context) == [
                 :approved,
                 :rejected,
                 :info_requested,
                 :cancelled
               ]
      end
    end

    test "is not available without the amount and threshold, where the country countersigns" do
      available = Lifecycle.available("ES", :in_review, :analyst)

      refute :approved in available
      refute :pending_countersign in available
      assert :rejected in available
    end
  end

  property "random sequences of transitions never leave a final state or skip the life cycle" do
    check all country <- member_of(Lifecycle.countries()),
              amount <- integer(1..10_000),
              steps <-
                list_of(
                  tuple({
                    member_of(Lifecycle.actors()),
                    integer(0..100),
                    member_of(Lifecycle.states()),
                    boolean()
                  }),
                  max_length: 60
                ) do
      context = %{amount_minor: amount, countersign_above_minor: 5_000}

      Enum.reduce(steps, :submitted, fn {actor, pick, random_target, follow?}, state ->
        available = Lifecycle.available(country, state, actor, context)

        target =
          if follow? and available != [],
            do: Enum.at(available, rem(pick, length(available))),
            else: random_target

        case Lifecycle.transition(country, state, target, actor, context) do
          {:ok, ^target} ->
            refute Lifecycle.final?(state)
            assert target in available
            assert target in Lifecycle.states(country)

            assert Enum.any?(
                     Lifecycle.transitions(country),
                     &(&1.from == state and &1.to == target and actor in &1.actors)
                   )

            target

          {:error, {:final_state, ^state}} ->
            assert Lifecycle.final?(state)
            state

          {:error, {:not_allowed, valid}} ->
            refute Lifecycle.final?(state)
            assert valid == available
            refute target in valid
            state
        end
      end)
    end
  end

  test "the Origination context lists the available transitions" do
    assert Fides.Origination.available_transitions("CO", :submitted, :system) == [:validating]
  end
end
