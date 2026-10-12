defmodule Fides.Accounts.Totp do
  @moduledoc """
  Second-factor codes of the staff: RFC 6238 (HMAC-SHA1, six digits, 30-second
  steps), accepting the previous and the next step for clock drift.

  `verify/3` returns the start of the step whose code matched. The sign-in stores it,
  and passing it back as `:since` marks that step and every earlier one as spent, so
  each code works once. Storing the time of the sign-in instead would let the code of
  the next step through twice.
  """

  @period 30
  @offsets [0, -1, 1]

  @doc """
  Checks `code` against `secret` at `:time` (unix seconds, default now). A code whose
  step is not after `:since` is `:spent`. Spaces in the code are ignored.
  """
  @spec verify(binary() | nil, term(), keyword()) ::
          {:ok, DateTime.t()} | {:error, :spent | :invalid}
  def verify(secret, code, opts \\ [])

  def verify(secret, code, opts) when is_binary(secret) and is_binary(code) do
    now = Keyword.get_lazy(opts, :time, fn -> System.os_time(:second) end)
    code = String.replace(code, ~r/\s/, "")

    # Every step is checked, so a wrong code costs the same as a right one
    steps =
      for offset <- @offsets,
          NimbleTOTP.valid?(secret, code, time: now + offset * @period),
          do: step_start(now + offset * @period)

    case Enum.reject(steps, &spent?(&1, opts[:since])) do
      [step | _others] -> {:ok, step}
      [] when steps != [] -> {:error, :spent}
      [] -> {:error, :invalid}
    end
  end

  def verify(_secret, _code, _opts), do: {:error, :invalid}

  @doc "The code of `secret` at `time` (unix seconds, default now)."
  @spec code(binary(), integer()) :: String.t()
  def code(secret, time \\ System.os_time(:second)),
    do: NimbleTOTP.verification_code(secret, time: time)

  @doc "Start of the step that contains `time` (unix seconds)."
  @spec step_start(integer()) :: DateTime.t()
  def step_start(time),
    do: DateTime.from_unix!(Integer.floor_div(time, @period) * @period * 1_000_000, :microsecond)

  @doc "Seconds left in the step that contains `time` (unix seconds)."
  @spec seconds_left(integer()) :: pos_integer()
  def seconds_left(time \\ System.os_time(:second)), do: @period - rem(time, @period)

  defp spent?(_step, nil), do: false
  defp spent?(step, since), do: DateTime.compare(step, since) != :gt
end
