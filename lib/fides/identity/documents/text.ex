defmodule Fides.Identity.Documents.Text do
  @moduledoc false
  # Name handling shared by the documents that encode the holder's names.

  @doc "The words of a name in uppercase ASCII: accents removed, punctuation dropped."
  def words(nil), do: []

  def words(text) do
    text
    |> String.upcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[^A-Z\s]/u, "")
    |> String.split()
  end

  @doc "Splits a word's letters into consonants and vowels, keeping their order."
  def consonants_and_vowels(word) do
    word |> String.to_charlist() |> Enum.split_with(&(&1 not in ~c"AEIOU"))
  end
end
