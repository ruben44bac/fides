defmodule Fides.Countries.Seeds do
  @moduledoc """
  The six launch countries. Each country is written in its own audited
  transaction, and running the seed again leaves the same rows.
  """

  alias Fides.Platform.AuditContext
  alias Fides.Platform.SystemActor

  @countries [
    %{
      code: "ES",
      currency: "EUR",
      default_locale: "es-ES",
      timezone: "Europe/Madrid",
      data_region: :eu
    },
    %{
      code: "PT",
      currency: "EUR",
      default_locale: "pt-PT",
      timezone: "Europe/Lisbon",
      data_region: :eu
    },
    %{
      code: "IT",
      currency: "EUR",
      default_locale: "it-IT",
      timezone: "Europe/Rome",
      data_region: :eu
    },
    %{
      code: "MX",
      currency: "MXN",
      default_locale: "es-MX",
      timezone: "America/Mexico_City",
      data_region: :latam
    },
    %{
      code: "CO",
      currency: "COP",
      default_locale: "es-CO",
      timezone: "America/Bogota",
      data_region: :latam
    },
    %{
      code: "BR",
      currency: "BRL",
      default_locale: "pt-BR",
      timezone: "America/Sao_Paulo",
      data_region: :latam
    }
  ]

  @spec countries() :: [map()]
  def countries, do: @countries

  @spec run() :: [Fides.Countries.Country.t()]
  def run do
    actor = SystemActor.new(:seeds)
    context = AuditContext.new(actor: SystemActor.audit_id(actor), reason: "seed reference data")

    Enum.map(@countries, fn attrs ->
      AuditContext.run(%{context | country: attrs.code}, fn ->
        Fides.Countries.seed_country!(Map.put(attrs, :status, :active), actor: actor)
      end)
    end)
  end
end
