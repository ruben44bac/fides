defmodule FidesWeb.PolicyForm do
  @moduledoc """
  A country's thresholds as a risk manager types them, checked and turned into the
  parameters a policy version takes, and the other way round: the version in force as
  the values to type, and each threshold with its unit, as a screen shows it. The
  unit comes from the threshold's name: amounts end in `minor`, and are typed in the
  country's units.
  """

  alias FidesWeb.Format
  alias FidesWeb.Money

  @typedoc "Errors by threshold, as a form shows them."
  @type errors :: [{atom(), {String.t(), keyword()}}]

  # What each known threshold is called and does, for people; the name says the rest
  @labels %{
    history_window_days: "History window",
    income_tolerance_percent: "Income tolerance",
    review_above_amount_minor: "Review above",
    countersign_above_minor: "Countersign above",
    approve_max_income_multiple: "Approve up to",
    review_max_income_multiple: "Review up to",
    min_income_months: "Months with income",
    min_monthly_income_minor: "Minimum monthly income",
    min_income_percent_of_amount: "Minimum income share",
    max_debt_income_multiple: "Maximum debt",
    approve_min_score: "Approve from",
    review_min_score: "Review from"
  }

  @descriptions %{
    history_window_days:
      "A rejection of the same holder within this many days sends a new application to review.",
    income_tolerance_percent:
      "If the bank sees a monthly income this much lower than the declared one, an analyst decides.",
    review_above_amount_minor: "Above this amount, the application goes to review.",
    countersign_above_minor:
      "An analyst's approval above this amount needs a risk manager's countersignature.",
    approve_max_income_multiple:
      "Up to this many times the monthly income, the application is approved.",
    review_max_income_multiple:
      "Up to this many times the monthly income, it goes to review; above, it is rejected.",
    min_income_months: "Months with income, out of the last six, the holder must show.",
    min_monthly_income_minor:
      "The lowest monthly income the bank must see in each of those months.",
    min_income_percent_of_amount: "The monthly income must be at least this share of the amount.",
    max_debt_income_multiple: "The total debt may be at most this many times the monthly income.",
    approve_min_score: "From this score up, the application is approved.",
    review_min_score:
      "From this score up to the approval score, it goes to review; below, it is rejected."
  }

  @doc "The unit a threshold is in, from its name."
  @spec unit(atom()) :: :amount | :percent | :days | :months | :multiple | :score | :number
  def unit(name) do
    cond do
      ends_with?(name, "_minor") -> :amount
      ends_with?(name, "_percent") or ends_with?(name, "_percent_of_amount") -> :percent
      ends_with?(name, "_days") -> :days
      ends_with?(name, "_months") -> :months
      ends_with?(name, "_multiple") -> :multiple
      ends_with?(name, "_score") -> :score
      true -> :number
    end
  end

  @doc "A threshold's name, for people, without its unit."
  @spec label(atom()) :: String.t()
  def label(name) do
    Map.get_lazy(@labels, name, fn ->
      name
      |> Atom.to_string()
      |> String.replace(~r/_(minor|percent_of_amount|percent|days|months|multiple|score)$/, "")
      |> String.replace("_", " ")
      |> String.capitalize()
    end)
  end

  @doc "What a threshold does, in a sentence, when it is a known one."
  @spec describe(atom()) :: String.t() | nil
  def describe(name), do: Map.get(@descriptions, name)

  @doc "The unit of a threshold as a short suffix next to its value: the currency, `%`, `days`…"
  @spec suffix(atom(), String.t()) :: String.t()
  def suffix(name, currency) do
    case unit(name) do
      :amount -> currency
      :percent -> "%"
      :days -> "days"
      :months -> "months"
      :multiple -> "× income"
      :score -> "points"
      :number -> ""
    end
  end

  @doc "A threshold's value as a screen shows it, in its unit."
  @spec format(atom(), integer(), String.t()) :: String.t()
  def format(name, value, currency) do
    case unit(name) do
      :amount -> Format.amount(value, currency)
      :percent -> "#{value} %"
      :days -> "#{value} days"
      :months -> "#{value} months"
      :multiple -> "#{value} × the income"
      :score -> "#{value} points"
      :number -> Integer.to_string(value)
    end
  end

  @doc "The values of a policy's parameters as they are typed: amounts in units."
  @spec values(map(), [atom()]) :: %{String.t() => String.t()}
  def values(params, names) do
    Map.new(names, fn name ->
      value = Map.get(params, name) || Map.get(params, Atom.to_string(name))
      {Atom.to_string(name), typed(name, value)}
    end)
  end

  @doc "The thresholds typed, as a policy version takes them, or the errors by threshold."
  @spec cast(map(), [atom()]) :: {:ok, %{atom() => non_neg_integer()}} | {:error, errors()}
  def cast(params, names) do
    {values, errors} =
      Enum.reduce(names, {%{}, []}, fn name, {values, errors} ->
        case parse(name, params[Atom.to_string(name)]) do
          {:ok, value} -> {Map.put(values, name, value), errors}
          {:error, message} -> {values, errors ++ [{name, {message, []}}]}
        end
      end)

    if errors == [], do: {:ok, values}, else: {:error, errors}
  end

  @doc "Each threshold with its value in force and the proposed one, and whether they differ."
  @spec diff(map() | nil, map(), [atom()]) :: [
          %{name: atom(), before: integer() | nil, after: integer(), changed?: boolean()}
        ]
  def diff(in_force, proposed, names) do
    for name <- names, Map.has_key?(proposed, name) do
      before = in_force && Map.get(in_force, name)
      %{name: name, before: before, after: proposed[name], changed?: before != proposed[name]}
    end
  end

  defp typed(_name, nil), do: ""

  defp typed(name, value),
    do: if(unit(name) == :amount, do: Money.units(value), else: to_string(value))

  defp parse(name, value) do
    case unit(name) do
      :amount -> amount(value)
      _other -> integer(value)
    end
  end

  defp amount(value) do
    case Money.parse(value) do
      {:ok, minor} -> {:ok, minor}
      :blank -> {:error, "is required"}
      :error -> {:error, "must be an amount such as 50000 or 50000.50"}
    end
  end

  defp integer(value) do
    case Integer.parse(String.trim(value || "")) do
      {integer, ""} when integer >= 0 ->
        {:ok, integer}

      {_negative, ""} ->
        {:error, "cannot be negative"}

      _other ->
        {:error,
         if(String.trim(value || "") == "", do: "is required", else: "must be a whole number")}
    end
  end

  defp ends_with?(name, suffix), do: name |> Atom.to_string() |> String.ends_with?(suffix)
end
