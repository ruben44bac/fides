defmodule Fides.Identity.Documents.ES do
  @moduledoc """
  Spain. DNI: eight digits and a control letter. NIE: X, Y or Z, seven digits and a
  control letter. The letter is the number modulo 23 in a fixed table, with the NIE
  prefix read as 0, 1 or 2.
  """

  @behaviour Fides.Identity.Documents.Validator

  @letters "TRWAGMYFPDXBNJZSQVHLCKE"
  @nie_prefixes %{"X" => "0", "Y" => "1", "Z" => "2"}

  @impl true
  def country, do: "ES"

  @impl true
  def document_types, do: ["DNI", "NIE"]

  @impl true
  def validate("DNI", document, _holder) do
    if document =~ ~r/^\d{8}[A-Z]$/ do
      {number, letter} = String.split_at(document, 8)
      check(number, letter)
    else
      {:error, [:invalid_format]}
    end
  end

  def validate("NIE", document, _holder) do
    if document =~ ~r/^[XYZ]\d{7}[A-Z]$/ do
      {prefix, rest} = String.split_at(document, 1)
      {number, letter} = String.split_at(rest, 7)
      check(Map.fetch!(@nie_prefixes, prefix) <> number, letter)
    else
      {:error, [:invalid_format]}
    end
  end

  @doc "The control letter of a DNI number, or of a NIE with its prefix already read as a digit."
  @spec control_letter(String.t()) :: String.t()
  def control_letter(number), do: String.at(@letters, rem(String.to_integer(number), 23))

  defp check(number, letter) do
    if control_letter(number) == letter,
      do: {:ok, nil},
      else: {:error, [:invalid_check_character]}
  end
end
