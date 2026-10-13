defmodule Fides.Notifications.SignatureTest do
  use ExUnit.Case, async: true

  alias Fides.Notifications.Signature

  @secret "a shared secret"
  @body ~s({"event_id":"evt_1","sequence":1})
  @now 1_700_000_000

  test "a signature made with the secret verifies within five minutes of its time" do
    signature = Signature.sign(@secret, @body, @now)

    assert "t=1700000000,v1=" <> digest = signature
    assert String.length(digest) == 64
    assert Signature.verify(@secret, signature, @body, @now) == :ok
    assert Signature.verify(@secret, signature, @body, @now + 299) == :ok
    assert Signature.verify(@secret, signature, @body, @now - 299) == :ok
  end

  test "an old signature, another body, another secret or a malformed header are refused" do
    signature = Signature.sign(@secret, @body, @now)

    assert Signature.verify(@secret, signature, @body, @now + 301) == {:error, :expired}
    assert Signature.verify(@secret, signature, @body <> " ", @now) == {:error, :invalid}
    assert Signature.verify("another secret", signature, @body, @now) == {:error, :invalid}

    for header <- [nil, "", "v1=abc", "t=1700000000,v1=short", "t=1700000000"] do
      assert Signature.verify(@secret, header, @body, @now) == {:error, :malformed}
    end
  end

  test "the Notifications context exports the scheme to the contexts that receive deliveries" do
    assert {:module, Fides.Notifications.Signature} =
             Code.ensure_loaded(Fides.Notifications.Signature)
  end
end
