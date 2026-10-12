defmodule Fides.Risk.EngineTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Fides.Risk.Engine
  alias Fides.Risk.Engine.Inputs

  @today ~D[2026-10-11]
  @severity %{approve: 0, review: 1, reject: 2}

  defp params(country) do
    {:ok, params} = Engine.default_params(country)
    params
  end

  defp evaluate(inputs) do
    {:ok, result} = Engine.evaluate(inputs, params(inputs.country))
    result
  end

  defp outcome(inputs), do: evaluate(inputs).outcome

  # Inputs that pass every common rule, so the country's rule decides on its own
  defp clean(country, fields) do
    struct!(
      Inputs,
      Keyword.merge(
        [
          country: country,
          amount_minor: 1_000_000,
          declared_income_minor: 500_000,
          observed_income_minor: 500_000,
          total_debt_minor: 0,
          score: 700,
          income_months: 6,
          document_valid?: true,
          adult?: true,
          evaluated_on: @today
        ],
        fields
      )
    )
  end

  defp inputs do
    gen all country <- member_of(Engine.countries()),
            amount <- integer(1..50_000_000),
            declared <- integer(1..5_000_000),
            observed <- integer(0..5_000_000),
            debt <- integer(0..50_000_000),
            score <- integer(0..1000),
            months <- integer(0..6),
            document_valid? <- boolean(),
            adult? <- member_of([true, false, nil]),
            rejected_days_ago <- one_of([constant(nil), integer(0..90)]) do
      %Inputs{
        country: country,
        amount_minor: amount,
        declared_income_minor: declared,
        observed_income_minor: observed,
        total_debt_minor: debt,
        score: score,
        income_months: months,
        document_valid?: document_valid?,
        adult?: adult?,
        previous_rejection_on: rejected_days_ago && Date.add(@today, -rejected_days_ago),
        evaluated_on: @today
      }
    end
  end

  property "the same inputs and policy give the same rules, outcome and hash" do
    check all inputs <- inputs() do
      first = evaluate(inputs)
      assert evaluate(inputs) == first
      assert byte_size(first.hash) == 32
      refute evaluate(%{inputs | amount_minor: inputs.amount_minor + 1}).hash == first.hash
    end
  end

  describe "country rules" do
    property "Spain sends amounts above 20 000 EUR to review" do
      check all amount <- integer(1..10_000_000) do
        expected = if amount > 2_000_000, do: :review, else: :approve
        assert outcome(clean("ES", amount_minor: amount)) == expected
      end
    end

    property "Portugal approves up to 6 times the income, reviews up to 8 and rejects above" do
      check all income <- integer(1..1_000_000), amount <- integer(1..10_000_000) do
        expected =
          cond do
            amount <= 6 * income -> :approve
            amount <= 8 * income -> :review
            true -> :reject
          end

        inputs =
          clean("PT",
            amount_minor: amount,
            declared_income_minor: income,
            observed_income_minor: income
          )

        assert outcome(inputs) == expected
      end
    end

    property "Italy approves income in each of the last six months of at least 1 200 EUR" do
      check all months <- integer(0..6), income <- integer(1..500_000) do
        expected = if months == 6 and income >= 120_000, do: :approve, else: :reject

        inputs =
          clean("IT",
            income_months: months,
            declared_income_minor: income,
            observed_income_minor: income
          )

        assert outcome(inputs) == expected
      end
    end

    property "Mexico approves a monthly income of at least 20% of the amount" do
      check all income <- integer(1..1_000_000), amount <- integer(1..10_000_000) do
        expected = if income * 5 >= amount, do: :approve, else: :reject

        inputs =
          clean("MX",
            amount_minor: amount,
            declared_income_minor: income,
            observed_income_minor: income
          )

        assert outcome(inputs) == expected
      end
    end

    property "Colombia approves a total debt of up to 5 times the monthly income" do
      check all income <- integer(1..1_000_000), debt <- integer(0..10_000_000) do
        expected = if debt <= 5 * income, do: :approve, else: :reject

        inputs =
          clean("CO",
            total_debt_minor: debt,
            declared_income_minor: income,
            observed_income_minor: income
          )

        assert outcome(inputs) == expected
      end
    end

    property "Brazil approves from 600, reviews from 450 and rejects below" do
      check all score <- integer(0..1000) do
        expected =
          cond do
            score >= 600 -> :approve
            score >= 450 -> :review
            true -> :reject
          end

        assert outcome(clean("BR", score: score)) == expected
      end
    end
  end

  describe "common rules" do
    property "failing eligibility rejects, whatever the country and history say" do
      check all inputs <- inputs(),
                failure <- member_of([:invalid_document, :underage, :no_declared_income]) do
        inputs =
          case failure do
            :invalid_document -> %{inputs | document_valid?: false}
            :underage -> %{inputs | adult?: false}
            :no_declared_income -> %{inputs | declared_income_minor: 0}
          end

        result = evaluate(inputs)
        assert result.outcome == :reject
        assert failure in result.reason_codes
      end
    end

    property "a rejection within 30 days sends to review, unless another rule rejects" do
      check all country <- member_of(Engine.countries()), days_ago <- integer(0..60) do
        inputs = clean(country, previous_rejection_on: Date.add(@today, -days_ago))
        result = evaluate(inputs)

        if days_ago < 30 do
          assert result.outcome == :review
          assert :recent_rejection in result.reason_codes
        else
          refute :recent_rejection in result.reason_codes
        end
      end
    end

    property "observed income more than 15% below the declared one sends to review" do
      check all country <- member_of(Engine.countries()),
                declared <- integer(200_000..1_000_000),
                observed <- integer(0..2_000_000) do
        inputs =
          clean(country,
            amount_minor: 100_000,
            declared_income_minor: declared,
            observed_income_minor: observed
          )

        result = evaluate(inputs)

        if observed * 100 < declared * 85 do
          assert :income_mismatch in result.reason_codes
          assert result.outcome in [:review, :reject]
        else
          refute :income_mismatch in result.reason_codes
        end
      end
    end
  end

  describe "metamorphic relations" do
    property "raising the observed income never worsens the outcome" do
      check all inputs <- inputs(), raise <- integer(0..5_000_000) do
        raised = %{inputs | observed_income_minor: inputs.observed_income_minor + raise}
        assert @severity[outcome(raised)] <= @severity[outcome(inputs)]
      end
    end

    property "raising the declared and observed income together never worsens the outcome" do
      check all inputs <- inputs(), raise <- integer(0..5_000_000) do
        raised = %{
          inputs
          | declared_income_minor: inputs.declared_income_minor + raise,
            observed_income_minor: inputs.observed_income_minor + raise
        }

        assert @severity[outcome(raised)] <= @severity[outcome(inputs)]
      end
    end

    property "raising the amount never improves the outcome" do
      check all inputs <- inputs(), raise <- integer(0..50_000_000) do
        raised = %{inputs | amount_minor: inputs.amount_minor + raise}
        assert @severity[outcome(raised)] >= @severity[outcome(inputs)]
      end
    end
  end

  test "the engine's inputs carry no personal data" do
    assert inputs_fields() == [
             :adult?,
             :amount_minor,
             :country,
             :declared_income_minor,
             :document_valid?,
             :evaluated_on,
             :income_months,
             :observed_income_minor,
             :previous_rejection_on,
             :score,
             :total_debt_minor
           ]
  end

  test "every policy carries a countersign threshold, and unknown countries have none" do
    for country <- Engine.countries() do
      assert %{countersign_above_minor: threshold} = params(country)
      assert is_integer(threshold) and threshold > 0
    end

    assert Engine.default_params("AR") == {:error, :unsupported_country}
    assert Engine.evaluate(clean("AR", []), %{}) == {:error, :unsupported_country}
  end

  test "the Risk context evaluates through its public functions" do
    {:ok, params} = Fides.Risk.default_params("ES")
    assert {:ok, %{outcome: :approve}} = Fides.Risk.evaluate(clean("ES", []), params)
  end

  describe "proposed thresholds" do
    test "are the country's own, read back from the database with string keys" do
      for country <- Engine.countries() do
        params = params(country)
        stored = Map.new(params, fn {name, value} -> {Atom.to_string(name), value} end)

        assert Engine.cast_params(country, params) == {:ok, params}
        assert Engine.cast_params(country, stored) == {:ok, params}
      end
    end

    test "must name every threshold and nothing else, as non-negative integers" do
      params = params("MX")

      assert {:error, "unknown thresholds: score"} =
               Engine.cast_params("MX", Map.put(params, "score", 1))

      assert {:error, "missing thresholds: countersign_above_minor"} =
               Engine.cast_params("MX", Map.delete(params, :countersign_above_minor))

      for value <- [-1, 1.5, "20", nil] do
        assert {:error, "thresholds must be non-negative integers: min_income_percent_of_amount"} =
                 Engine.cast_params("MX", %{params | min_income_percent_of_amount: value})
      end

      assert {:error, "unknown thresholds: {1}"} =
               Engine.cast_params("MX", Map.put(params, {1}, 1))

      assert {:error, "must be a map of thresholds"} = Engine.cast_params("MX", [])
      assert {:error, "AR has no policy"} = Engine.cast_params("AR", %{})
    end

    test "must keep bands in order and within what the bank reports" do
      assert {:error, "approve_max_income_multiple" <> _} =
               Engine.cast_params("PT", %{params("PT") | approve_max_income_multiple: 9})

      assert {:error, "review_min_score" <> _} =
               Engine.cast_params("BR", %{params("BR") | review_min_score: 700})

      assert {:error, "approve_min_score" <> _} =
               Engine.cast_params("BR", %{params("BR") | approve_min_score: 1001})

      assert {:error, "min_income_months" <> _} =
               Engine.cast_params("IT", %{params("IT") | min_income_months: 7})
    end
  end

  defp inputs_fields do
    %Inputs{
      country: "ES",
      amount_minor: 1,
      declared_income_minor: 1,
      observed_income_minor: 1,
      total_debt_minor: 0,
      score: 0,
      income_months: 0,
      document_valid?: true,
      evaluated_on: @today
    }
    |> Map.from_struct()
    |> Map.keys()
    |> Enum.sort()
  end
end
