defmodule Fides.AI.CaseBrief do
  @moduledoc """
  The brief of a case for the analyst who reviews it: the configured model writes a
  summary and the signals to look at first, from the pseudonymized facts alone, in a
  structured answer the guardrails check. An answer that fails them is asked for once
  more with the failure; after that, or when the model fails, the template stands in.
  The brief assists: it never moves an application.
  """

  alias Fides.AI.CaseBrief.Guardrails
  alias Fides.AI.CaseBrief.Template

  @prompt_version "1"

  @doc "Writes the brief of `application` with the configured model, and records the run."
  @spec run(struct(), term()) :: {:ok, struct()} | {:error, term()}
  def run(application, actor) do
    started = System.monotonic_time(:millisecond)
    model = Fides.AI.model()

    with {:ok, input} <- input(application, actor) do
      prompt = prompt(input)
      {answer, guardrails, outcome, error} = ask(model, prompt, input)

      Fides.AI.record_ai_run(
        %{
          capability: :case_brief,
          model: model.name(),
          subject_id: application.id,
          lock_version: application.lock_version,
          prompt_hash: hash(prompt),
          input_hash: hash(input),
          output: answer.output,
          guardrails: guardrails,
          outcome: outcome,
          tokens_in: answer.tokens_in,
          tokens_out: answer.tokens_out,
          cost_usd: answer.cost_usd,
          latency_ms: System.monotonic_time(:millisecond) - started,
          error: error
        },
        tenant: application.country_code,
        actor: actor
      )
    end
  end

  @doc """
  What the model gets: the terms, and the latest decision with what every rule said
  and the canonical inputs it decided on. Financial and public data only.
  """
  @spec input(struct(), term()) :: {:ok, map()} | {:error, term()}
  def input(application, actor) do
    with {:ok, decisions} <-
           Fides.Risk.decisions(application.country_code, application.id, actor) do
      {:ok,
       %{
         application_id: application.id,
         country: application.country_code,
         currency: application.currency,
         state: application.state,
         revision: application.revision,
         amount_minor: application.amount_minor,
         declared_income_minor: application.monthly_income_minor,
         decision: decision(List.first(decisions))
       }}
    end
  end

  @doc "The prompt a model gets: the task, the shape of the answer, and the input as JSON."
  @spec prompt(map()) :: String.t()
  def prompt(input) do
    """
    You assist a credit analyst. Write a brief of the application below for them: it helps them
    review; it never decides. Answer with a JSON object only, with two keys: "summary", a
    paragraph of at most four sentences, and "signals", a list of short strings, one per thing
    the analyst should look at first. Mention every rule whose outcome is not "approve", by its
    name with spaces instead of underscores. Use only numbers that appear in the input, writing
    amounts as the currency code and the amount with two decimals, such as EUR 25,000.00; amounts
    in the input are integers in minor units (cents). Never invent facts, and never include
    names, documents or email addresses: there are none here, and none should appear.

    Input (prompt version #{@prompt_version}):
    #{Jason.encode!(input)}
    """
  end

  # The model's answer if it passes, once more with the failure if it does not, and the
  # template when all else fails
  defp ask(model, prompt, input) do
    case model.brief(prompt, input) do
      {:ok, answer} -> judge(model, prompt, input, answer, 1)
      {:error, reason} -> {template(input), :skipped, :fallback, describe(reason)}
    end
  end

  defp judge(model, prompt, input, answer, attempt) do
    case Guardrails.check(answer.output, input) do
      :ok ->
        {answer, :passed, :model, nil}

      {:error, refusals} when attempt == 1 ->
        retry =
          prompt <> "\n\nYour previous answer was refused: #{inspect(refusals)}. Answer again.\n"

        case model.brief(retry, input) do
          {:ok, again} -> judge(model, prompt, input, add(again, answer), 2)
          {:error, reason} -> {template(input), :failed, :fallback, describe(reason)}
        end

      {:error, refusals} ->
        {template(input) |> add(answer), :failed, :fallback, "guardrails: #{inspect(refusals)}"}
    end
  end

  # What the second answer cost adds to the first
  defp add(answer, previous) do
    %{
      answer
      | tokens_in: answer.tokens_in + previous.tokens_in,
        tokens_out: answer.tokens_out + previous.tokens_out,
        cost_usd: sum(answer.cost_usd, previous.cost_usd)
    }
  end

  defp sum(nil, cost), do: cost
  defp sum(cost, nil), do: cost
  defp sum(cost, more), do: Decimal.add(cost, more)

  defp template(input),
    do: %{output: Template.render(input), tokens_in: 0, tokens_out: 0, cost_usd: nil}

  # Decisions come back with string keys and values; the brief works with atoms
  defp decision(nil), do: nil

  defp decision(decision) do
    inputs = decision.inputs

    %{
      outcome: to_string(decision.outcome),
      reason_codes: Enum.map(decision.reason_codes, &to_string/1),
      rules:
        Enum.map(decision.rule_results, fn result ->
          %{
            rule: to_string(field(result, :rule)),
            outcome: to_string(field(result, :outcome)),
            reason_codes: Enum.map(field(result, :reason_codes) || [], &to_string/1)
          }
        end),
      inputs: %{
        amount_minor: field(inputs, :amount_minor),
        declared_income_minor: field(inputs, :declared_income_minor),
        observed_income_minor: field(inputs, :observed_income_minor),
        total_debt_minor: field(inputs, :total_debt_minor),
        score: field(inputs, :score),
        income_months: field(inputs, :income_months),
        document_valid?: field(inputs, :document_valid?),
        adult?: field(inputs, :adult?),
        previous_rejection_on: field(inputs, :previous_rejection_on),
        evaluated_on: field(inputs, :evaluated_on)
      }
    }
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp describe(reason) when is_exception(reason), do: Exception.message(reason)
  defp describe(reason), do: inspect(reason)

  defp hash(term) when is_binary(term), do: :crypto.hash(:sha256, term)
  defp hash(term), do: :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
end
