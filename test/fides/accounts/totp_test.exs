defmodule Fides.Accounts.TotpTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Fides.Accounts.Totp

  # RFC 6238, appendix B, with the last six digits of each SHA-1 code
  @rfc_secret "12345678901234567890"
  @rfc_codes [
    {59, "287082"},
    {1_111_111_109, "081804"},
    {1_111_111_111, "050471"},
    {1_234_567_890, "005924"},
    {2_000_000_000, "279037"},
    {20_000_000_000, "353130"}
  ]

  # Around this time the RFC secret's codes differ from step to step, so no result
  # depends on two codes coinciding
  @time 1_760_000_000

  test "codes follow RFC 6238" do
    for {time, code} <- @rfc_codes do
      assert Totp.code(@rfc_secret, time) == code
      assert Totp.verify(@rfc_secret, code, time: time) == {:ok, Totp.step_start(time)}
    end
  end

  test "the previous and the next step are accepted, and no further" do
    for offset <- [-30, 0, 30] do
      code = Totp.code(@rfc_secret, @time + offset)
      assert Totp.verify(@rfc_secret, code, time: @time) == {:ok, Totp.step_start(@time + offset)}
    end

    for offset <- [-60, 60] do
      code = Totp.code(@rfc_secret, @time + offset)
      assert Totp.verify(@rfc_secret, code, time: @time) == {:error, :invalid}
    end
  end

  test "a code is spent once its step, or a later one, was used" do
    code = Totp.code(@rfc_secret, @time)
    {:ok, spent} = Totp.verify(@rfc_secret, code, time: @time)

    assert Totp.verify(@rfc_secret, code, time: @time, since: spent) == {:error, :spent}
    assert Totp.verify(@rfc_secret, code, time: @time + 15, since: spent) == {:error, :spent}

    next = Totp.code(@rfc_secret, @time + 30)
    assert {:ok, _step} = Totp.verify(@rfc_secret, next, time: @time + 30, since: spent)
  end

  test "the next step's code, accepted early, is spent when its step comes" do
    early = Totp.code(@rfc_secret, @time + 30)
    {:ok, spent} = Totp.verify(@rfc_secret, early, time: @time)

    assert spent == Totp.step_start(@time + 30)
    assert Totp.verify(@rfc_secret, early, time: @time + 30, since: spent) == {:error, :spent}
  end

  test "spaces in a code are ignored, and anything else is refused" do
    code = Totp.code(@rfc_secret, 59)
    spaced = String.slice(code, 0, 3) <> " " <> String.slice(code, 3, 3)

    assert {:ok, _step} = Totp.verify(@rfc_secret, spaced, time: 59)
    assert Totp.verify(@rfc_secret, "28708", time: 59) == {:error, :invalid}
    assert Totp.verify(@rfc_secret, <<0xFF, 0xFE>>, time: 59) == {:error, :invalid}
    assert Totp.verify(@rfc_secret, nil, time: 59) == {:error, :invalid}
    assert Totp.verify(nil, code, time: 59) == {:error, :invalid}
  end

  property "the code of any moment verifies at that moment, in its own step" do
    check all secret <- binary(length: 20),
              time <- integer(30..4_000_000_000) do
      step = Totp.step_start(time)

      assert Totp.verify(secret, Totp.code(secret, time), time: time) == {:ok, step}
      assert DateTime.to_unix(step) <= time and time - DateTime.to_unix(step) < 30
      assert Totp.seconds_left(time) == 30 - (time - DateTime.to_unix(step))
    end
  end
end
