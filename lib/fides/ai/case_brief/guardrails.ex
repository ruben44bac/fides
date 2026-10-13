defmodule Fides.AI.CaseBrief.Guardrails do
  @moduledoc """
  What a brief must satisfy before an analyst sees it: it has the shape the capability
  expects, every number in it exists in the input, every rule that objected is
  mentioned, and nothing in it looks like personal data. Pure checks, so a model's
  answer is judged the same way every time.
  """

  @max_summary 1_500

  @typedoc "Why a brief was refused."
  @type refusal ::
          :schema | {:unbacked_numbers, [String.t()]} | {:rules_missing, [String.t()]} | :pii

  @spec check(term(), map()) :: :ok | {:error, [refusal()]}
  def check(output, input) do
    case schema(output) do
      :ok ->
        text = text(output)

        refusals =
          Enum.reject(
            [numbers(text, input), rules(text, input), pii(text)],
            &(&1 == :ok)
          )

        if refusals == [], do: :ok, else: {:error, refusals}

      :error ->
        {:error, [:schema]}
    end
  end

  defp schema(%{"summary" => summary, "signals" => signals})
       when is_binary(summary) and is_list(signals) do
    if String.trim(summary) != "" and String.length(summary) <= @max_summary and
         Enum.all?(signals, &is_binary/1),
       do: :ok,
       else: :error
  end

  defp schema(_output), do: :error

  defp text(%{"summary" => summary, "signals" => signals}),
    do: Enum.join([summary | signals], "\n")

  # Every number in the text, commas aside, is a number of the input
  defp numbers(text, input) do
    allowed = allowed_numbers(input)

    unbacked =
      ~r/\d[\d,]*(?:\.\d+)?/
      |> Regex.scan(text)
      |> List.flatten()
      |> Enum.map(&String.replace(&1, ",", ""))
      |> Enum.reject(&(&1 in allowed))
      |> Enum.uniq()

    if unbacked == [], do: :ok, else: {:unbacked_numbers, unbacked}
  end

  defp rules(_text, %{decision: nil}), do: :ok

  defp rules(text, %{decision: decision}) do
    lower = String.downcase(text)

    missing =
      for rule <- decision.rules,
          rule.outcome != "approve",
          not String.contains?(lower, label(rule.rule)),
          do: label(rule.rule)

    if missing == [], do: :ok, else: {:rules_missing, missing}
  end

  # No address, and no run of digits long enough to be a document or an account
  defp pii(text) do
    if String.contains?(text, "@") or Regex.match?(~r/\d{8,}/, String.replace(text, ~r/[,.]/, "")),
      do: :pii,
      else: :ok
  end

  defp allowed_numbers(input) do
    amounts = [input.amount_minor, input.declared_income_minor] ++ decision_amounts(input)
    counts = decision_counts(input)
    dates = decision_dates(input)

    Enum.flat_map(amounts, &amount_forms/1) ++
      Enum.map(counts, &Integer.to_string/1) ++
      Enum.flat_map(dates, &date_forms/1) ++ ["6"]
  end

  defp decision_amounts(%{decision: nil}), do: []

  defp decision_amounts(%{decision: %{inputs: inputs}}),
    do: [
      inputs.amount_minor,
      inputs.declared_income_minor,
      inputs.observed_income_minor,
      inputs.total_debt_minor
    ]

  defp decision_counts(%{decision: nil}), do: []
  defp decision_counts(%{decision: %{inputs: inputs}}), do: [inputs.score, inputs.income_months]

  defp decision_dates(%{decision: nil}), do: []

  defp decision_dates(%{decision: %{inputs: inputs}}),
    do: Enum.reject([inputs.previous_rejection_on, inputs.evaluated_on], &is_nil/1)

  # An amount may be written in units with cents, or whole
  defp amount_forms(minor) when is_integer(minor) do
    units = div(minor, 100)
    cents = minor |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")
    ["#{units}.#{cents}", Integer.to_string(units)]
  end

  defp amount_forms(_other), do: []

  defp date_forms(date) do
    text = to_string(date)
    [text | String.split(text, "-")]
  end

  defp label(rule), do: rule |> to_string() |> String.replace("_", " ")
end
