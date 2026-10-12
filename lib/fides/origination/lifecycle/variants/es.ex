defmodule Fides.Origination.Lifecycle.Variants.ES do
  @moduledoc """
  Spain: bank data comes back with the request, and an approval above the policy's
  threshold needs a risk manager's countersignature.
  """

  @behaviour Fides.Origination.Lifecycle.Variant

  @impl true
  def country, do: "ES"

  @impl true
  def bank_data, do: :sync

  @impl true
  def countersign?, do: true
end
