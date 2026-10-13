defmodule Fides.AI.CaseBrief.Template do
  @moduledoc """
  The brief without a model: a summary and the signals an analyst looks at first,
  written from the pseudonymized input alone. It is what the simulated model answers,
  and what stands in when a model fails or its answer does not pass the guardrails.
  Every number in it comes from the input, so it always passes them.
  """

  @doc "The structured brief: a summary and a list of signals."
  @spec render(map()) :: %{String.t() => String.t() | [String.t()]}
  def render(input) do
    %{"summary" => summary(input), "signals" => signals(input)}
  end

  defp summary(%{decision: nil} = input) do
    "Application for #{money(input.amount_minor, input.currency)} against a declared monthly " <>
      "income of #{money(input.declared_income_minor, input.currency)}. The policy has not " <>
      "decided it yet."
  end

  defp summary(%{decision: decision} = input) do
    inputs = decision.inputs

    "Application for #{money(input.amount_minor, input.currency)} against a declared monthly " <>
      "income of #{money(input.declared_income_minor, input.currency)}, which the bank " <>
      "#{bank(inputs, input.currency)}. The policy #{verdict(decision)}. " <>
      "#{document(inputs)} #{history(inputs)}"
  end

  defp signals(%{decision: nil}), do: []

  defp signals(%{decision: decision} = input) do
    inputs = decision.inputs

    failed =
      for rule <- decision.rules, rule.outcome != "approve" do
        "#{label(rule.rule)}: #{Enum.map_join(rule.reason_codes, ", ", &label/1)} (#{rule.outcome})"
      end

    failed ++
      [income_signal(inputs, input.currency), debt_signal(inputs, input.currency)] ++
      if(inputs.previous_rejection_on,
        do: ["Rejected before, on #{inputs.previous_rejection_on}"],
        else: []
      )
  end

  defp bank(inputs, currency) do
    "observes at #{money(inputs.observed_income_minor, currency)}, with a score of " <>
      "#{inputs.score} and income in #{inputs.income_months} of the last 6 months"
  end

  defp verdict(%{outcome: "approve"}), do: "approved it"
  defp verdict(%{outcome: "reject"} = decision), do: "rejected it: " <> reasons(decision)
  defp verdict(%{outcome: "review"} = decision), do: "sent it to review: " <> reasons(decision)
  defp verdict(decision), do: "said #{decision.outcome}: " <> reasons(decision)

  defp reasons(decision) do
    case for(rule <- decision.rules, rule.outcome != "approve", do: label(rule.rule)) do
      [] -> "no rule objected"
      rules -> Enum.join(rules, ", ")
    end
  end

  defp document(%{document_valid?: false}), do: "The document did not pass validation."
  defp document(%{adult?: false}), do: "The holder is not of age according to the document."
  defp document(_inputs), do: "The document is valid."

  defp history(%{previous_rejection_on: nil}), do: "No earlier rejection."

  defp history(%{previous_rejection_on: date}),
    do: "An earlier application was rejected on #{date}."

  defp income_signal(inputs, currency) do
    declared = inputs.declared_income_minor
    observed = inputs.observed_income_minor

    if observed >= declared,
      do: "Declared income #{money(declared, currency)} is backed by the bank",
      else:
        "Bank sees #{money(observed, currency)} a month, below the declared #{money(declared, currency)}"
  end

  defp debt_signal(inputs, currency),
    do: "Total debt #{money(inputs.total_debt_minor, currency)}"

  defp label(value), do: value |> to_string() |> String.replace("_", " ")

  @doc "An amount in minor units with its currency, as the brief writes it: `EUR 25,000.00`."
  @spec money(integer(), String.t()) :: String.t()
  def money(minor, currency) do
    units =
      minor
      |> div(100)
      |> Integer.to_string()
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
      |> String.reverse()

    cents = minor |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{currency} #{units}.#{cents}"
  end
end
