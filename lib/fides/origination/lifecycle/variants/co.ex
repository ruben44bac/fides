defmodule Fides.Origination.Lifecycle.Variants.CO do
  @moduledoc "Colombia: bank data comes back with the request, and an analyst's approval is final."

  @behaviour Fides.Origination.Lifecycle.Variant

  @impl true
  def country, do: "CO"

  @impl true
  def bank_data, do: :sync

  @impl true
  def countersign?, do: false
end
