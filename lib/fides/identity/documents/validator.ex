defmodule Fides.Identity.Documents.Validator do
  @moduledoc """
  What each country implements to validate its documents. The document arrives
  normalized: uppercase, without spaces, dots or dashes.
  """

  alias Fides.Identity.Documents.Holder

  @doc "ISO 3166-1 alpha-2 code of the country."
  @callback country() :: String.t()

  @doc "Codes of the document types the country accepts."
  @callback document_types() :: [String.t()]

  @doc """
  Validates a document. Returns the birth date the document encodes, or nil when it
  encodes none, or every reason the document is invalid.
  """
  @callback validate(type :: String.t(), document :: String.t(), Holder.t()) ::
              {:ok, Date.t() | nil} | {:error, [atom()]}
end
