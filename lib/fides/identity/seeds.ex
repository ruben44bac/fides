defmodule Fides.Identity.Seeds do
  @moduledoc """
  The document types each launch country accepts, taken from the document validators.
  Running the seed again leaves the same rows.
  """

  alias Fides.Identity.Documents
  alias Fides.Platform.AuditContext
  alias Fides.Platform.SystemActor

  @spec run() :: [Fides.Identity.DocumentType.t()]
  def run do
    actor = SystemActor.new(:seeds)
    context = AuditContext.new(actor: SystemActor.audit_id(actor), reason: "seed reference data")

    for country <- Documents.countries(), code <- Documents.document_types(country) do
      AuditContext.run(%{context | country: country}, fn ->
        Fides.Identity.seed_document_type!(%{code: code, active: true},
          tenant: country,
          actor: actor
        )
      end)
    end
  end
end
