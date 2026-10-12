defmodule Fides.Platform.VaultTest do
  # Rotating keys changes application config, which other tests read
  use ExUnit.Case, async: false

  alias Fides.Platform.BlindIndex
  alias Fides.Platform.Vault

  setup do
    original = Application.fetch_env!(:fides, Vault)
    on_exit(fn -> Application.put_env(:fides, Vault, original) end)
    %{keys: Keyword.fetch!(original, :keys)}
  end

  test "values round-trip and each encryption is different" do
    first = Vault.encrypt!("12345678Z")

    assert Vault.decrypt!(first) == "12345678Z"
    refute Vault.encrypt!("12345678Z") == first
  end

  test "a tampered value does not decrypt" do
    value = Vault.encrypt!("12345678Z")
    size = byte_size(value) - 1
    <<head::binary-size(^size), last>> = value
    tampered = <<head::binary, Bitwise.bxor(last, 1)>>

    assert_raise ArgumentError, ~r/tampered/, fn -> Vault.decrypt!(tampered) end
  end

  @tag spec: "IDEN-10"
  test "rotating the encryption key keeps old values readable and the hashes unchanged", %{
    keys: keys
  } do
    old_value = Vault.encrypt!("12345678Z")
    document_hash = BlindIndex.document("ES", "12345678Z")
    email_hash = BlindIndex.email("zoila.quintana@example.com")

    Application.put_env(:fides, Vault, keys: [{"V2", :crypto.strong_rand_bytes(32)} | keys])

    assert Vault.decrypt!(old_value) == "12345678Z"
    assert <<2, "V2", _rest::binary>> = Vault.encrypt!("12345678Z")
    assert BlindIndex.document("ES", "12345678Z") == document_hash
    assert BlindIndex.email("zoila.quintana@example.com") == email_hash
  end

  test "a value under an unknown key is rejected" do
    value = Vault.encrypt!("12345678Z")
    Application.put_env(:fides, Vault, keys: [{"V9", :crypto.strong_rand_bytes(32)}])

    assert_raise ArgumentError, ~r/no encryption key tagged/, fn -> Vault.decrypt!(value) end
  end

  test "hashes use a canonical form of each value" do
    assert BlindIndex.document("ES", "12345678-z") == BlindIndex.document("ES", "12345678Z")
    refute BlindIndex.document("PT", "12345678Z") == BlindIndex.document("ES", "12345678Z")
    assert BlindIndex.email(" Zoila@Example.com ") == BlindIndex.email("zoila@example.com")
  end
end
