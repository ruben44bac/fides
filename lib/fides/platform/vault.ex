defmodule Fides.Platform.Vault do
  @moduledoc """
  Encrypts personal data at rest with AES-256-GCM, which also authenticates it: a
  tampered value fails to decrypt instead of decrypting to something else.

  Keys are listed newest first as `{tag, key}`. New values use the first one, and
  each value carries the tag of the key that encrypted it, so a new key can become
  the default while values under older keys still decrypt. Development and tests
  derive their key from a fixed phrase; production reads it from
  `FIDES_ENCRYPTION_KEY`.

  A value is stored as the tag's length and the tag, then the 12-byte IV, the
  16-byte authentication tag and the ciphertext.
  """

  @aad "fides"

  @spec encrypt!(binary()) :: binary()
  def encrypt!(plaintext) when is_binary(plaintext) do
    [{tag, key} | _older] = keys()
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, auth_tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, @aad, 16, true)

    <<byte_size(tag)::8, tag::binary, iv::binary, auth_tag::binary, ciphertext::binary>>
  end

  @spec decrypt!(binary()) :: binary()
  def decrypt!(
        <<tag_length::8, tag::binary-size(tag_length), iv::binary-12, auth_tag::binary-16,
          ciphertext::binary>>
      ) do
    key =
      case List.keyfind(keys(), tag, 0) do
        {^tag, key} -> key
        nil -> raise ArgumentError, "no encryption key tagged #{inspect(tag)}"
      end

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, @aad, auth_tag, false) do
      :error -> raise ArgumentError, "the value was tampered with or the key is wrong"
      plaintext -> plaintext
    end
  end

  defp keys, do: Keyword.fetch!(Application.fetch_env!(:fides, __MODULE__), :keys)
end
