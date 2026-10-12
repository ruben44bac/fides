defmodule Fides.Origination.Lifecycle.Variants.MX do
  @moduledoc """
  Mexico: the bank provider accepts the request and delivers the data later through a
  signed webhook, so the application waits for it. An analyst's approval is final.
  """

  @behaviour Fides.Origination.Lifecycle.Variant

  @impl true
  def country, do: "MX"

  @impl true
  def bank_data, do: :async

  @impl true
  def countersign?, do: false
end
