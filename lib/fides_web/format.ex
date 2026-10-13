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
  def state(state), do: state |> Atom.to_string() |> String.replace("_", " ")

  @doc "The first characters of an id, enough to tell applications apart on a screen."
  @spec short_id(String.t()) :: String.t()
  def short_id(id), do: String.slice(id, 0, 8)

  @doc "A moment as the screen shows it, in UTC."
  @spec moment(DateTime.t()) :: String.t()
  def moment(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M")

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
