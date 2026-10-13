defmodule FidesWeb.ApplicationForm do
  @moduledoc """
  What a member of staff types to submit an application, checked and turned into the
  submission the application's own action takes: amounts in the country's units become
  minor units, the currency is the country's, the channel is this form, and the
  holder's document is checked against their data the way the action checks it again.
  Each error names the field that caused it, and the action's own errors are read back
  onto the same fields.
  """

  alias Fides.Identity

  @typedoc "Where the actor may submit: each country's currency and document types."
  @type catalog :: %{String.t() => %{currency: String.t(), document_types: [String.t()]}}

  @typedoc "Errors by field, as a form shows them."
  @type errors :: [{atom(), {String.t(), keyword()}}]

  @holder_fields [
    :given_names,
    :first_surname,
    :second_surname,
    :document_type,
    :document,
    :email
  ]
  @required [:given_names, :first_surname, :document_type, :document, :email]
  @about_the_document [
    :country,
    :document_type,
    :document,
    :given_names,
    :first_surname,
    :second_surname,
    :birth_date,
    :sex
  ]

  # Units with up to two decimals, after a dot or a comma
  @amount ~r/^\d{1,13}(?:[.,]\d{1,2})?$/

  # The action's fields on the form's; anything else lands on the holder
  @read_back %{
    amount_minor: :amount,
    monthly_income_minor: :monthly_income,
    person_id: :holder,
    currency: :country,
    channel: :holder,
    consent_text_version: :consent
  }

  @doc "The holder's data a document type is checked against, besides their names."
  @spec needed(String.t() | nil, String.t() | nil) :: [:birth_date | :sex]
  def needed(country, type) when is_binary(country) and is_binary(type),
    do: Identity.holder_data_needed(country, type)

  def needed(_country, _type), do: []

  @doc "Checks what was typed: the country and the submission for the action, or the errors by field."
  @spec cast(map(), catalog(), String.t()) :: {:ok, String.t(), map()} | {:error, errors()}
  def cast(params, catalog, consent_version) do
    country = params["country"]
    entry = Map.get(catalog, country)
    holder = Map.new(@holder_fields, &{&1, text(params[Atom.to_string(&1)])})
    needed = if entry, do: needed(country, holder.document_type), else: []

    errors =
      Enum.concat([
        if(entry, do: [], else: [country: {"is not one of your countries", []}]),
        amount_errors(:amount, params["amount"]),
        amount_errors(:monthly_income, params["monthly_income"]),
        for(field <- @required, holder[field] == nil, do: {field, {"is required", []}}),
        document_type_errors(entry, country, holder.document_type),
        birth_date_errors(params["birth_date"], :birth_date in needed, holder.document_type),
        sex_errors(params["sex"], :sex in needed, holder.document_type),
        if(params["consent"] == "true", do: [], else: [consent: {"must be confirmed", []}])
      ])

    holder = Map.merge(holder, %{birth_date: date(params["birth_date"]), sex: sex(params["sex"])})
    errors = errors ++ document_errors(errors, country, holder)

    if errors == [] do
      {:ok, country,
       %{
         amount_minor: minor!(params["amount"]),
         monthly_income_minor: minor!(params["monthly_income"]),
         currency: entry.currency,
         channel: :form,
         consent_text_version: consent_version,
         holder: Map.reject(holder, fn {_field, value} -> is_nil(value) end)
       }}
    else
      {:error, errors}
    end
  end

  @doc "The action's errors, read back onto the form's fields."
  @spec errors_from(Exception.t()) :: errors()
  def errors_from(%{errors: errors}) when is_list(errors), do: Enum.map(errors, &read_back/1)
  def errors_from(error), do: [holder: {message(error), []}]

  defp read_back(%{field: field} = error) when is_atom(field) and not is_nil(field) do
    {Map.get(@read_back, field, field),
     {label(error_message(error)), Map.get(error, :vars) || []}}
  end

  defp read_back(error), do: {:holder, {message(error), []}}

  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(%Ash.Error.Changes.Required{}), do: "is required"
  defp error_message(error), do: message(error)

  defp amount_errors(field, value) do
    case minor(value) do
      {:ok, minor} when minor > 0 -> []
      {:ok, _zero} -> [{field, {"must be more than zero", []}}]
      :blank -> [{field, {"is required", []}}]
      :error -> [{field, {"must be an amount such as 25000 or 25000.50", []}}]
    end
  end

  defp minor(value) do
    case text(value) do
      nil -> :blank
      amount -> amount |> String.replace(" ", "") |> units_and_cents()
    end
  end

  defp units_and_cents(amount) do
    if Regex.match?(@amount, amount) do
      {units, cents} =
        case String.split(amount, ~r/[.,]/) do
          [units] -> {units, "00"}
          [units, cents] -> {units, String.pad_trailing(cents, 2, "0")}
        end

      {:ok, String.to_integer(units) * 100 + String.to_integer(cents)}
    else
      :error
    end
  end

  defp minor!(value) do
    {:ok, minor} = minor(value)
    minor
  end

  defp document_type_errors(nil, _country, _type), do: []
  defp document_type_errors(_entry, _country, nil), do: []

  defp document_type_errors(entry, country, type) do
    if type in entry.document_types,
      do: [],
      else: [document_type: {"is not a document of #{country}", []}]
  end

  defp birth_date_errors(value, needed?, type) do
    case {text(value), needed?} do
      {nil, true} -> [birth_date: {"is required for a #{type}", []}]
      {nil, false} -> []
      {_text, _needed?} -> if date(value), do: [], else: [birth_date: {"must be a date", []}]
    end
  end

  defp sex_errors(value, needed?, type) do
    case {text(value), needed?} do
      {nil, true} -> [sex: {"is required for a #{type}", []}]
      {value, _needed?} when value in [nil, "female", "male"] -> []
      _other -> [sex: {"is not one of the options", []}]
    end
  end

  # The document is checked once everything it is checked against is in order
  defp document_errors(errors, country, holder) do
    blocked? = Enum.any?(errors, fn {field, _error} -> field in @about_the_document end)

    if blocked? do
      []
    else
      case Identity.validate_document(country, holder.document_type, holder.document, holder) do
        {:ok, _checked} ->
          []

        {:error, reasons} ->
          [document: {"is not valid: " <> Enum.map_join(reasons, ", ", &label/1), []}]
      end
    end
  end

  defp date(value) do
    case Date.from_iso8601(text(value) || "") do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  defp sex("female"), do: :female
  defp sex("male"), do: :male
  defp sex(_other), do: nil

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp text(_other), do: nil

  defp label(value), do: value |> to_string() |> String.replace("_", " ")

  defp message(error) when is_exception(error), do: Exception.message(error)
  defp message(error), do: inspect(error)
end
