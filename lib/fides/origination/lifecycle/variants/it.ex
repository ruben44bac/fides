defmodule Fides.Origination.Lifecycle.Variants.IT do
  @moduledoc """
  Italy: bank data comes back with the request, and an approval above the policy's
  threshold needs a risk manager's countersignature.
  """

  @behaviour Fides.Origination.Lifecycle.Variant

  @impl true
  def country, do: "IT"

  @impl true
  def bank_data, do: :sync

  @impl true
  def countersign?, do: true
end
