defmodule Fides.Identity.Documents.CO do
  @moduledoc """
  Colombia. Cédula de ciudadanía: six to ten digits. It has no check digit, so only
  the format is validated.
  """

  @behaviour Fides.Identity.Documents.Validator

  @impl true
  def country, do: "CO"

  @impl true
  def document_types, do: ["CC"]

  @impl true
  def validate("CC", document, _holder) do
    if document =~ ~r/^\d{6,10}$/, do: {:ok, nil}, else: {:error, [:invalid_format]}
  end
end
