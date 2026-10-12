defmodule Fides.Origination.LifecycleTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Fides.Origination.Lifecycle

  @humans [:applicant, :analyst, :risk_manager]
  @within %{amount_minor: 4_000, countersign_above_minor: 5_000}
  @above %{amount_minor: 6_000, countersign_above_minor: 5_000}

  @tag spec: "ORIG-04"
  test "a transition the life cycle does not allow fails with the valid ones" do
    assert Lifecycle.transition("MX", :submitted, :approved, :system) ==
             {:error, {:not_allowed, [:validating]}}

    assert Lifecycle.transition("MX", :submitted, :validating, :system) == {:ok, :validating}
  end

  @tag spec: "ORIG-06"
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

  @tag spec: "ORIG-07"
  test "final states have no way out" do
    for country <- Lifecycle.countries(),
        state <- Lifecycle.final_states(),
        actor <- Lifecycle.actors(),
        target <- Lifecycle.states() do
      assert Lifecycle.transition(country, state, target, actor, @above) ==
               {:error, {:final_state, state}}
    end
  end

  @tag spec: "ORIG-08"
  test "every open state can be cancelled by the applicant and by an analyst" do
    for country <- Lifecycle.countries(),
        state <- Lifecycle.states() -- Lifecycle.final_states(),
        actor <- [:applicant, :analyst] do
      assert Lifecycle.transition(country, state, :cancelled, actor) == {:ok, :cancelled}
    end
  end

  @tag spec: "ORIG-12"
  test "reevaluation returns to evaluating only from review, and only by the system" do
    for country <- Lifecycle.countries() do
      into_evaluating =
        for %{to: :evaluating} = transition <- Lifecycle.transitions(country),
            do: {transition.from, transition.actors}

      assert Enum.sort(into_evaluating) == [awaiting_bank_data: [:system], in_review: [:system]]
    end
  end

  @tag spec: "ORIG-13"
  test "an analyst's approval above the countersign threshold needs a risk manager" do
    assert :approved in Lifecycle.available("ES", :in_review, :analyst, @within)
    refute :pending_countersign in Lifecycle.available("ES", :in_review, :analyst, @within)

    assert :pending_countersign in Lifecycle.available("ES", :in_review, :analyst, @above)
    refute :approved in Lifecycle.available("ES", :in_review, :analyst, @above)

    assert Lifecycle.available("ES", :pending_countersign, :risk_manager) == [
             :approved,
             :in_review
           ]

    assert Lifecycle.available("ES", :pending_countersign, :analyst) == [:cancelled]
  end

  test "without the amount and threshold neither approval path is available" do
    available = Lifecycle.available("BR", :in_review, :analyst)

    refute :approved in available
    refute :pending_countersign in available
    assert :rejected in available
  end

  @tag spec: "ORIG-15"
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
