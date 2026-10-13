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

  @doc """
  What a document itself encodes about its holder, such as the birth date and the
  sex, or an empty map when the document is malformed. A stored holder's document can
  then be checked again without the data that was not kept. Only countries whose
  documents encode the holder's data implement it.
  """
  @callback encoded(type :: String.t(), document :: String.t()) :: %{
              optional(:birth_date) => Date.t(),
              optional(:sex) => :female | :male | nil
            }

  @doc """
  The holder's data, besides their names, a document type is checked against, so a
  form can ask for it. Only countries whose documents encode such data implement it.
  """
  @callback needs(type :: String.t()) :: [:birth_date | :sex]

  @optional_callbacks encoded: 2, needs: 1
end
