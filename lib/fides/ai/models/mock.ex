defmodule Fides.AI.Models.Mock do
  @moduledoc """
  The simulated model, active by default: it answers every brief with the template,
  at once and for free, so nothing needs a key and every test and demo runs without
  the network.
  """

  @behaviour Fides.AI.Model

  alias Fides.AI.CaseBrief.Template

  @impl true
  def name, do: "mock"

  @impl true
  def brief(_prompt, input),
    do: {:ok, %{output: Template.render(input), tokens_in: 0, tokens_out: 0, cost_usd: nil}}
end
