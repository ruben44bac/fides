defmodule Fides.Identity.Documents.MX do
  @moduledoc """
  Mexico. CURP: 18 characters built from the holder's surnames and given name, the
  birth date, the sex and the state of birth, plus a check digit.

  The holder's names and birth date must match what the CURP encodes, and the sex
  too when given. The birth date returned is the one the CURP encodes, which settles
  whether the holder is an adult.

  Names follow the official rules: Ñ counts as X, particles such as DE, LA or DEL are
  skipped, MARÍA and JOSÉ give way to the second given name, and a first block that
  spells an offensive word gets an X as its second letter.
  """

  @behaviour Fides.Identity.Documents.Validator

  alias Fides.Identity.Documents.Text

  @states ~w(AS BC BS CC CL CM CS CH DF DG GT GR HG JC MC MN MS NT NL OC PL QT QR SP SL SR TC TS
             TL VZ YN ZS NE)
  @particles ~w(DA DAS DE DEL DER DI DIE DD EL LA LOS LAS LE LES MAC MC VAN VON Y)
  # MARÍA and JOSÉ, and their abbreviations MA. and J., are so common as first given
  # names that the CURP takes the initial of the second given name when there is one:
  # "María Fernanda" gives F, not M.
  @common_first_names ~w(MARIA MA JOSE J)
  # Offensive words from the official CURP rules. When the first four letters spell one
  # of them, the second letter becomes an X: P-U-T-O is issued as PXTO. Without this
  # substitution, valid CURPs of real people would be rejected as not matching their name.
  @offensive ~w(BACA BAKA BUEI BUEY CACA CACO CAGA CAGO CAKA CAKO COGE COGI COJA COJE COJI COJO
                COLA CULO FALO FETO GETA GUEI GUEY JETA JOTO KACA KACO KAGA KAGO KAKA KAKO KOGE
                KOGI KOJA KOJE KOJI KOJO KOLA KULO LILO LOCA LOCO LOKA LOKO MAME MAMO MEAR MEAS
                MEON MIAR MION MOCO MOKO MULA MULO NACA NACO PEDA PEDO PENE PIPI PITO POPO PUTA
                PUTO QULO RATA ROBA ROBE ROBO RUIN SENO TETA VACA VAGA VAGO VAKA VUEI VUEY WUEI
                WUEY)

  @impl true
  def country, do: "MX"

  @impl true
  def document_types, do: ["CURP"]

  @impl true
  def needs("CURP"), do: [:birth_date]

  @impl true
  def validate("CURP", document, holder) do
    with :ok <- format(document),
         :ok <- check(document),
         {:ok, birth_date} <- birth_date(document),
         :ok <- complete(holder) do
      case mismatches(document, birth_date, holder) do
        [] -> {:ok, birth_date}
        reasons -> {:error, reasons}
      end
    end
  end

  @impl true
  def encoded("CURP", document) do
    with :ok <- format(document),
         {:ok, birth_date} <- birth_date(document) do
      %{birth_date: birth_date, sex: sex(String.at(document, 10))}
    else
      _malformed -> %{}
    end
  end

  @doc "The four letters the CURP takes from the surnames and the given name."
  @spec name_code(map()) :: String.t()
  def name_code(holder) do
    first = surname(holder.first_surname)

    code =
      initial(first) <>
        first_internal(first, :vowel) <>
        initial(surname(holder.second_surname)) <>
        initial(given_name(holder.given_names))

    if code in @offensive,
      do: String.slice(code, 0, 1) <> "X" <> String.slice(code, 2, 2),
      else: code
  end

  @doc "The three consonants the CURP takes from the surnames and the given name."
  @spec consonant_code(map()) :: String.t()
  def consonant_code(holder) do
    first_internal(surname(holder.first_surname), :consonant) <>
      first_internal(surname(holder.second_surname), :consonant) <>
      first_internal(given_name(holder.given_names), :consonant)
  end

  @doc "The check digit of the first seventeen characters."
  @spec check_digit(String.t()) :: 0..9
  def check_digit(body) do
    sum =
      body
      |> String.to_charlist()
      |> Enum.with_index()
      |> Enum.reduce(0, fn {char, index}, sum -> sum + value(char) * (18 - index) end)

    rem(10 - rem(sum, 10), 10)
  end

  defp format(document) do
    if document =~ ~r/^[A-Z][AEIOUX][A-Z]{2}\d{6}[HMX][A-Z]{2}[B-DF-HJ-NP-TV-Z]{3}[A-Z\d]\d$/ and
         String.slice(document, 11, 2) in @states,
       do: :ok,
       else: {:error, [:invalid_format]}
  end

  defp check(document) do
    {body, digit} = String.split_at(document, 17)

    if Integer.to_string(check_digit(body)) == digit,
      do: :ok,
      else: {:error, [:invalid_check_digit]}
  end

  # The century comes from the 17th character: a digit for births before 2000
  defp birth_date(document) do
    <<_names::binary-size(4), year::binary-size(2), month::binary-size(2), day::binary-size(2),
      _middle::binary-size(6), differentiator, _check::binary>> = document

    century = if differentiator in ?0..?9, do: 1900, else: 2000

    case Date.new(
           century + String.to_integer(year),
           String.to_integer(month),
           String.to_integer(day)
         ) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, [:invalid_format]}
    end
  end

  defp complete(holder) do
    if holder.given_names && holder.first_surname && holder.birth_date,
      do: :ok,
      else: {:error, [:missing_holder_data]}
  end

  defp mismatches(document, birth_date, holder) do
    Enum.filter(
      [
        (String.slice(document, 0, 4) != name_code(holder) or
           String.slice(document, 13, 3) != consonant_code(holder)) && :name_mismatch,
        birth_date != holder.birth_date && :birth_date_mismatch,
        sex_mismatch?(String.at(document, 10), holder.sex) && :sex_mismatch
      ],
      & &1
    )
  end

  defp sex("H"), do: :male
  defp sex("M"), do: :female
  defp sex(_other), do: nil

  defp sex_mismatch?(_code, nil), do: false
  defp sex_mismatch?("H", :male), do: false
  defp sex_mismatch?("M", :female), do: false
  defp sex_mismatch?(_code, _sex), do: true

  defp surname(text), do: text |> name_words() |> List.first("")

  defp given_name(text) do
    case name_words(text) do
      [first, second | _rest] when first in @common_first_names -> second
      [first | _rest] -> first
      [] -> ""
    end
  end

  defp name_words(nil), do: []

  defp name_words(text) do
    text
    |> String.replace(["Ñ", "ñ"], "X")
    |> Text.words()
    |> Enum.reject(&(&1 in @particles))
  end

  defp initial(""), do: "X"
  defp initial(word), do: String.first(word)

  defp first_internal("", _kind), do: "X"

  defp first_internal(word, kind) do
    [_first | rest] = String.to_charlist(word)

    case Enum.find(rest, &(&1 in ~c"AEIOU" == (kind == :vowel))) do
      nil -> "X"
      char -> <<char>>
    end
  end

  defp value(char) when char in ?0..?9, do: char - ?0
  defp value(char) when char in ?A..?N, do: char - ?A + 10
  # Ñ sits between N and O in the official table, so the letters after it shift by one
  defp value(char), do: char - ?A + 11
end
