defmodule Fides.AI.Model do
  @moduledoc """
  What a model behind a capability implements: a name for the record, and the brief
  of a case from its prompt and its pseudonymized input. The answer is the structured
  output the capability expects, with what the invocation cost; the capability checks
  it before showing it, and falls back to its template when it cannot be used.
  """

  @typedoc "A model's answer: the structured output and what it cost."
  @type answer :: %{
          output: map(),
          tokens_in: non_neg_integer(),
          tokens_out: non_neg_integer(),
          cost_usd: Decimal.t() | nil
        }

  @doc "The model's name, as the run records it."
  @callback name() :: String.t()

  @doc "Writes the brief the prompt asks for, from the input the prompt describes."
  @callback brief(prompt :: String.t(), input :: map()) :: {:ok, answer()} | {:error, term()}
end
