defmodule Fides.Origination.Lifecycle.Variants.BR do
  @moduledoc "Brazil: bank data comes back with the request, and an analyst's approval is final."

  @behaviour Fides.Origination.Lifecycle.Variant

  @impl true
  def country, do: "BR"

  @impl true
  def bank_data, do: :sync

  @impl true
  def countersign?, do: false
end
