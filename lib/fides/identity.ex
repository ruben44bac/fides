defmodule Fides.Identity do
  @moduledoc """
  Identity context: who a credit belongs to. It validates identity documents by
  country and keeps each holder once per document and country.
  """

  use Fides.Platform.Domain,
    boundary: [deps: [Fides.Platform], exports: []]

  require Ash.Query

  resources do
    resource Fides.Identity.DocumentType do
      define :list_document_types, action: :read
      define :seed_document_type, action: :seed
    end

    resource Fides.Identity.Person do
      define :resolve_person, action: :resolve
      define :get_person, action: :read, get_by: [:id]
    end

    resource Fides.Identity.Consent do
      define :accept_consent, action: :accept
      define :list_consents, action: :read
    end
  end

  @doc """
  The holder of a document in a country, or nil. Found by the document's keyed hash,
  so nothing is decrypted.
  """
  @spec holder_of_document(String.t(), String.t()) ::
          {:ok, Fides.Identity.Person.t() | nil} | {:error, term()}
  def holder_of_document(country, document) do
    hash = Fides.Platform.BlindIndex.document(country, document)

    Fides.Identity.Person
    |> Ash.Query.filter(document_hash == ^hash)
    |> Ash.read_one(tenant: country, authorize?: false)
  end

  @doc "Validates a document for a country, against the holder's data when the document encodes it."
  defdelegate validate_document(country, type, document, holder \\ %{}),
    to: Fides.Identity.Documents,
    as: :validate

  @doc "Whether someone born on `birth_date` is an adult on `today`."
  defdelegate adult?(birth_date, today), to: Fides.Identity.Documents
end
