defmodule Fides.Identity.Documents do
  @moduledoc """
  Validates identity documents for each country.

  Pure functions with no database and no Ash, so every rule can be tested on its own.
  Each country implements `Fides.Identity.Documents.Validator`; this module only finds
  the country's validator and normalizes the document first: uppercase, without
  spaces, dots or dashes.

  A valid document returns the normalized document and, when the document encodes
  it, the holder's birth date. An invalid one returns every reason found.
  """

  use Boundary, type: :strict, deps: [], exports: [Holder]

  alias Fides.Identity.Documents.BR
  alias Fides.Identity.Documents.CO
  alias Fides.Identity.Documents.ES
  alias Fides.Identity.Documents.Holder
  alias Fides.Identity.Documents.IT
  alias Fides.Identity.Documents.MX
  alias Fides.Identity.Documents.PT

  @validators [ES, PT, IT, MX, CO, BR]

  @type result :: %{
          country: String.t(),
          type: String.t(),
          document: String.t(),
          birth_date: Date.t() | nil
        }

  @doc "Countries with a document validator."
  @spec countries() :: [String.t()]
  def countries, do: Enum.map(@validators, & &1.country())

  @doc "Document types accepted in a country."
  @spec document_types(String.t()) :: [String.t()]
  def document_types(country) do
    case validator(country) do
      {:ok, validator} -> validator.document_types()
      {:error, _reasons} -> []
    end
  end

  @spec validate(String.t(), String.t(), String.t(), Holder.t() | map() | keyword()) ::
          {:ok, result()} | {:error, [atom()]}
  def validate(country, type, document, holder \\ %{}) do
    normalized = normalize(document)

    with {:ok, validator} <- validator(country),
         :ok <- supported(validator, type),
         {:ok, birth_date} <- validator.validate(type, normalized, Holder.new(holder)) do
      {:ok, %{country: country, type: type, document: normalized, birth_date: birth_date}}
    end
  end

  @doc "Whether someone born on `birth_date` is at least 18 years old on `today`."
  @spec adult?(Date.t(), Date.t()) :: boolean()
  def adult?(%Date{} = birth_date, %Date{} = today) do
    Date.compare(Date.shift(birth_date, year: 18), today) != :gt
  end

  defp validator(country) do
    case Enum.find(@validators, &(&1.country() == country)) do
      nil -> {:error, [:unsupported_country]}
      validator -> {:ok, validator}
    end
  end

  defp supported(validator, type) do
    if type in validator.document_types(), do: :ok, else: {:error, [:unsupported_document_type]}
  end

  defp normalize(document) when is_binary(document) do
    document |> String.upcase() |> String.replace(~r/[\s.\-]/u, "")
  end

  defp normalize(_document), do: ""
end
