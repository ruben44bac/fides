defmodule Fides.Origination.TransitionNotAllowed do
  @moduledoc """
  A move the application's life cycle does not allow for the actor, with the states
  the actor may move it to instead. A final state allows none.
  """

  use Splode.Error, fields: [:from, :to, :available], class: :invalid

  def message(error), do: summary(error)

  @doc "The refusal in one sentence, with the allowed states."
  @spec summary(Exception.t()) :: String.t()
  def summary(%{from: from, to: to, available: available}) do
    allowed = if available == [], do: "none", else: Enum.join(available, ", ")
    "cannot move from #{from} to #{to}; allowed: #{allowed}"
  end
end
