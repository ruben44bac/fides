defmodule Fides.Identity.Documents.IT do
  @moduledoc """
  Italy. Codice fiscale: 16 characters encoding the surname, the given names, the
  birth date, the sex and the birthplace, plus a control character.

  Omocodia is accepted: when two people would share a code, letters replace some of
  its digits. The holder's names, birth date and sex must match what the code encodes.
  The birthplace is not checked against the official list of places.
  """

  @behaviour Fides.Identity.Documents.Validator

  alias Fides.Identity.Documents.Text

  @months ~c"ABCDEHLMPRST"
  @omocodia ~c"LMNPQRSTUV"
  # Positions of the original code that hold digits and may carry omocodia letters
  @numeric_positions [6, 7, 9, 10, 12, 13, 14]
  # Value of each character in an odd position, for 0..9 and for A..Z alike
  @odd_values {1, 0, 5, 7, 9, 13, 15, 17, 19, 21, 2, 4, 18, 20, 11, 3, 6, 8, 12, 14, 16, 10, 22,
               25, 24, 23}

  @impl true
  def country, do: "IT"

  @impl true
  def document_types, do: ["CF"]

  @impl true
  def validate("CF", document, holder) do
    with :ok <- format(document),
         :ok <- control(document),
         :ok <- complete(holder) do
      case mismatches(decode_omocodia(document), holder) do
        [] -> {:ok, holder.birth_date}
        reasons -> {:error, reasons}
      end
    end
  end

  @doc "The three letters the code takes from the surnames."
  @spec surname_code(map()) :: String.t()
  def surname_code(holder) do
    letters = Enum.join(Text.words(holder.first_surname) ++ Text.words(holder.second_surname))
    {consonants, vowels} = Text.consonants_and_vowels(letters)
    pad(consonants ++ vowels)
  end

  @doc "The three letters the code takes from the given names."
  @spec name_code(String.t() | nil) :: String.t()
  def name_code(given_names) do
    {consonants, vowels} =
      given_names |> Text.words() |> Enum.join() |> Text.consonants_and_vowels()

    case consonants do
      [first, _second, third, fourth | _rest] -> List.to_string([first, third, fourth])
      _few -> pad(consonants ++ vowels)
    end
  end

  @doc "The five characters the code takes from the birth date and the sex."
  @spec date_code(Date.t(), :female | :male) :: String.t()
  def date_code(%Date{} = date, sex) do
    day = if sex == :female, do: date.day + 40, else: date.day
    two_digits(rem(date.year, 100)) <> month_code(date.month) <> two_digits(day)
  end

  @doc "The control character of the first fifteen characters."
  @spec control_character(String.t()) :: String.t()
  def control_character(body) do
    sum =
      body
      |> String.to_charlist()
      |> Enum.with_index()
      |> Enum.reduce(0, fn {char, index}, sum ->
        sum + if(rem(index, 2) == 0, do: odd_value(char), else: even_value(char))
      end)

    <<?A + rem(sum, 26)>>
  end

  @doc "The code with every omocodia letter replaced by the digit it stands for."
  @spec decode_omocodia(String.t()) :: String.t()
  def decode_omocodia(code) do
    code
    |> String.to_charlist()
    |> Enum.with_index()
    |> Enum.map(fn {char, index} ->
      if index in @numeric_positions and char in @omocodia,
        do: ?0 + Enum.find_index(@omocodia, &(&1 == char)),
        else: char
    end)
    |> List.to_string()
  end

  defp format(document) do
    pattern =
      ~r/^[A-Z]{6}[\dLMNPQRSTUV]{2}[ABCDEHLMPRST][\dLMNPQRSTUV]{2}[A-Z][\dLMNPQRSTUV]{3}[A-Z]$/

    if document =~ pattern, do: :ok, else: {:error, [:invalid_format]}
  end

  defp control(document) do
    {body, control} = String.split_at(document, 15)
    if control_character(body) == control, do: :ok, else: {:error, [:invalid_check_character]}
  end

  defp complete(holder) do
    if holder.given_names && holder.first_surname && holder.birth_date && holder.sex,
      do: :ok,
      else: {:error, [:missing_holder_data]}
  end

  defp mismatches(code, holder) do
    <<surname::binary-size(3), names::binary-size(3), year::binary-size(2), month::binary-size(1),
      day::binary-size(2), _place::binary>> = code

    day = String.to_integer(day)
    date = holder.birth_date

    Enum.filter(
      [
        (surname != surname_code(holder) or names != name_code(holder.given_names)) &&
          :name_mismatch,
        (year != two_digits(rem(date.year, 100)) or month != month_code(date.month) or
           rem(day, 40) != date.day) && :birth_date_mismatch,
        day > 40 != (holder.sex == :female) && :sex_mismatch
      ],
      & &1
    )
  end

  defp odd_value(char) when char in ?0..?9, do: elem(@odd_values, char - ?0)
  defp odd_value(char), do: elem(@odd_values, char - ?A)

  defp even_value(char) when char in ?0..?9, do: char - ?0
  defp even_value(char), do: char - ?A

  defp pad(chars), do: (chars ++ ~c"XXX") |> Enum.take(3) |> List.to_string()
  defp month_code(month), do: <<Enum.at(@months, month - 1)>>
  defp two_digits(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")
end
