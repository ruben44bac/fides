defmodule FidesWeb.Format do
  @moduledoc "How the backoffice shows amounts, states and dates."

  @doc "An amount in minor units with its currency, such as `EUR 25,000.00`."
  @spec amount(integer(), String.t()) :: String.t()
  def amount(minor, currency) do
    units = minor |> div(100) |> Integer.to_string() |> thousands()
    cents = minor |> rem(100) |> abs() |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{currency} #{units}.#{cents}"
  end

  @doc "A state's name for people."
  @spec state(atom()) :: String.t()
  def state(state), do: label(state)

  @doc "An atom, or a string with underscores, as words: `income_mismatch` is `income mismatch`."
  @spec label(atom() | String.t() | nil) :: String.t()
  def label(nil), do: ""
  def label(value), do: value |> to_string() |> String.replace("_", " ")

  @doc """
  Who wrote something, as the evidence names them: `staff · 0199ab12` for a staff
  user, `orchestrator` for the system, `risk agent` for an agent.
  """
  @spec actor(String.t() | nil) :: String.t()
  def actor("staff_user:" <> id), do: "staff · " <> short_id(id)
  def actor("system:" <> name), do: label(name)
  def actor("agent:" <> name), do: label(name) <> " agent"
  def actor(nil), do: "unknown"
  def actor(other), do: other

  @doc "The first characters of an id, enough to tell applications apart on a screen."
  @spec short_id(String.t()) :: String.t()
  def short_id(id), do: String.slice(id, 0, 8)

  @doc "The first characters of a hash, in hex."
  @spec digest(binary()) :: String.t()
  def digest(hash), do: hash |> Base.encode16(case: :lower) |> String.slice(0, 12)

  @doc "An integer with its thousands separated."
  @spec number(integer()) :: String.t()
  def number(integer), do: integer |> Integer.to_string() |> thousands()

  @doc "A duration in milliseconds: `12 ms`, or `1.2 s` from a second on."
  @spec duration(non_neg_integer()) :: String.t()
  def duration(ms) when ms < 1000, do: "#{ms} ms"
  def duration(ms), do: "#{Float.round(ms / 1000, 1)} s"

  @doc "A moment as the screen shows it, in UTC."
  @spec moment(DateTime.t()) :: String.t()
  def moment(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M")

  @doc "A moment to the second, in UTC, for a sequence of events."
  @spec instant(DateTime.t()) :: String.t()
  def instant(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S")

  @doc "How long ago a moment was, for a glance: just now, 3 min ago, 2 h ago, 4 d ago, or the date."
  @spec relative(DateTime.t(), DateTime.t()) :: String.t()
  def relative(%DateTime{} = at, now \\ DateTime.utc_now()) do
    seconds = DateTime.diff(now, at, :second)

    cond do
      seconds < 60 -> "just now"
      seconds < 3_600 -> "#{div(seconds, 60)} min ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)} h ago"
      seconds < 7 * 86_400 -> "#{div(seconds, 86_400)} d ago"
      true -> Calendar.strftime(at, "%Y-%m-%d")
    end
  end

  defp thousands(digits) do
    digits
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
