defmodule Fides.Identity do
  @moduledoc """
  Identity context: who a credit belongs to. It validates identity documents by
  country and keeps each holder once per document and country.
  """

  use Fides.Platform.Domain,
    boundary: [deps: [Fides.Platform], exports: []]

  @doc "Validates a document for a country, against the holder's data when the document encodes it."
  defdelegate validate_document(country, type, document, holder \\ %{}),
    to: Fides.Identity.Documents,
    as: :validate

  @doc "Whether someone born on `birth_date` is an adult on `today`."
  defdelegate adult?(birth_date, today), to: Fides.Identity.Documents
end
