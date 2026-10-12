defmodule Fides.Banking.Seeds do
  @moduledoc """
  One simulated bank provider per launch country, each with its own format. Mexico's
  answers asynchronously, through a webhook. Running the seed again leaves the same rows.
  """

  alias Fides.Platform.AuditContext
  alias Fides.Platform.SystemActor

  @providers [
    %{country: "ES", name: "Simulated Spanish bank", mode: :sync, adapter: "es_json"},
    %{country: "PT", name: "Simulated Portuguese bank", mode: :sync, adapter: "pt_json"},
    %{country: "IT", name: "Simulated Italian bank", mode: :sync, adapter: "it_xml"},
    %{country: "MX", name: "Simulated Mexican bank", mode: :async, adapter: "mx_webhook"},
    %{country: "CO", name: "Simulated Colombian bank", mode: :sync, adapter: "co_json"},
    %{country: "BR", name: "Simulated Brazilian bank", mode: :sync, adapter: "br_json"}
  ]

  @spec providers() :: [map()]
  def providers, do: @providers

  @spec run() :: [Fides.Banking.BankProvider.t()]
  def run do
    actor = SystemActor.new(:seeds)
    context = AuditContext.new(actor: SystemActor.audit_id(actor), reason: "seed reference data")

    for %{country: country} = provider <- @providers do
      AuditContext.run(%{context | country: country}, fn ->
        Fides.Banking.seed_bank_provider!(Map.delete(provider, :country),
          tenant: country,
          actor: actor
        )
      end)
    end
  end
end
