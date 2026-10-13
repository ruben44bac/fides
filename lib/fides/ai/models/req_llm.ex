defmodule Fides.AI.Models.ReqLLM do
  @moduledoc """
  A real model through ReqLLM, named by its spec such as `anthropic:claude-haiku-5-5`,
  with the provider's key taken from the environment as ReqLLM expects. It asks for
  the brief as JSON and reads it back; anything else is an error, and the capability
  falls back to its template.
  """

  @behaviour Fides.AI.Model

  @impl true
  def name, do: spec()

  @impl true
  def brief(prompt, _input) do
    with {:ok, response} <-
           ReqLLM.generate_text(spec(), prompt, max_tokens: 600, temperature: 0.0),
         {:ok, output} <- parse(ReqLLM.Response.text(response)) do
      usage = ReqLLM.Response.usage(response) || %{}

      {:ok,
       %{
         output: output,
         tokens_in: Map.get(usage, :input_tokens, 0),
         tokens_out: Map.get(usage, :output_tokens, 0),
         cost_usd: cost(Map.get(usage, :total_cost))
       }}
    end
  end

  # The model may wrap the JSON in a code fence
  defp parse(nil), do: {:error, :empty_answer}

  defp parse(text) do
    text
    |> String.trim()
    |> String.replace(~r/\A```(?:json)?\s*|\s*```\z/, "")
    |> Jason.decode()
    |> case do
      {:ok, %{} = output} -> {:ok, output}
      {:ok, _other} -> {:error, :not_an_object}
      {:error, _reason} -> {:error, :not_json}
    end
  end

  defp cost(nil), do: nil
  defp cost(%Decimal{} = cost), do: cost
  defp cost(cost) when is_float(cost), do: Decimal.from_float(cost)
  defp cost(cost) when is_integer(cost), do: Decimal.new(cost)
  defp cost(_other), do: nil

  defp spec,
    do:
      :fides
      |> Application.get_env(Fides.AI, [])
      |> Keyword.get(:spec, "anthropic:claude-haiku-5-5")
end
