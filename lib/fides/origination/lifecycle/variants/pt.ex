defmodule Fides.Origination.Lifecycle.Variants.PT do
  @moduledoc """
  Portugal: bank data comes back with the request, and an approval above the policy's
  threshold needs a risk manager's countersignature.
  """

  @behaviour Fides.Origination.Lifecycle.Variant

  @impl true
  def country, do: "PT"

  @impl true
  def bank_data, do: :sync

  @impl true
  def countersign?, do: true
end
