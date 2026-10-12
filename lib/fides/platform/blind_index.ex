defmodule Fides.Platform.BlindIndex do
  @moduledoc """
  Keyed hashes (HMAC-SHA256) that let Fides find a holder by document or by email
  without storing either in clear. The key is not the encryption key, so rotating the
  encryption key never changes a hash.

  Each value is hashed in a canonical form, so the same document or email always
  gives the same hash:

    * a document: the country code and the document in uppercase, without spaces,
      dots or dashes;
    * an email: trimmed and in lowercase. Emails are not tied to a country, so a
      portal user and a holder with the same email share the hash.
  """

  @spec document(String.t(), String.t()) :: binary()
  def document(country, document) do
    canonical = document |> String.upcase() |> String.replace(~r/[\s.\-]/u, "")
    hmac("document|" <> country <> "|" <> canonical)
  end

  @spec email(String.t()) :: binary()
  def email(email), do: hmac("email|" <> (email |> String.trim() |> String.downcase()))

  defp hmac(data), do: :crypto.mac(:hmac, :sha256, key(), data)

  defp key, do: Keyword.fetch!(Application.fetch_env!(:fides, __MODULE__), :key)
end
