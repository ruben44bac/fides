defmodule Fides.Identity.Generators do
  @moduledoc """
  StreamData generators of valid documents for each country, of the holders they
  belong to, and of single-character mutations of a document.
  """

  use Boundary, top_level?: true, check: [in: false, out: false]

  import ExUnitProperties
  import StreamData

  alias Fides.Identity.Documents.BR
  alias Fides.Identity.Documents.ES
  alias Fides.Identity.Documents.IT
  alias Fides.Identity.Documents.MX
  alias Fides.Identity.Documents.PT

  @given_names [
    "María José",
    "José Luis",
    "Ana",
    "Giulia",
    "Ñuño",
    "Lucía",
    "Marco Antonio",
    "Ma. Fernanda",
    "J. Carlos",
    "Chiara",
    "Iñaki",
    "Bea",
    "Ugo",
    "Ai"
  ]
  @surnames [
    "Hernández",
    "García",
    "De la Cruz",
    "Rossi",
    "Di Stefano",
    "Núñez",
    "Ochoa",
    "Iriarte",
    "Mc Gregor",
    "D'Angelo",
    "Yáñez",
    "Oyuela",
    "Eu"
  ]
  @omocodia ~c"LMNPQRSTUV"
  @nie_prefixes %{"X" => "0", "Y" => "1", "Z" => "2"}

  def digits(count), do: string(?0..?9, length: count)

  def dni, do: map(digits(8), &(&1 <> ES.control_letter(&1)))

  def nie do
    gen all prefix <- member_of(Map.keys(@nie_prefixes)), number <- digits(7) do
      prefix <> number <> ES.control_letter(Map.fetch!(@nie_prefixes, prefix) <> number)
    end
  end

  def nif, do: map(digits(8), &(&1 <> Integer.to_string(PT.check_digit(&1))))

  def cpf do
    digits(9)
    |> filter(&(not (&1 =~ ~r/^(\d)\1+$/)))
    |> map(&(&1 <> BR.check_digits(&1)))
  end

  def cedula do
    gen(all(length <- integer(6..10), number <- digits(length), do: number))
  end

  def holder do
    gen all given_names <- name(@given_names),
            first_surname <- name(@surnames),
            second_surname <- one_of([constant(nil), name(@surnames)]),
            birth_date <- birth_date(),
            sex <- member_of([:female, :male]) do
      %{
        given_names: given_names,
        first_surname: first_surname,
        second_surname: second_surname,
        birth_date: birth_date,
        sex: sex
      }
    end
  end

  @doc "A holder and a valid codice fiscale for them, sometimes with omocodia letters."
  def italian do
    gen all holder <- holder(),
            place <- string(?A..?Z, length: 1),
            place_number <- digits(3),
            omocodia <- list_of(member_of([6, 7, 9, 10, 12, 13, 14]), max_length: 3) do
      body =
        IT.surname_code(holder) <>
          IT.name_code(holder.given_names) <>
          IT.date_code(holder.birth_date, holder.sex) <> place <> place_number

      body = Enum.reduce(omocodia, body, &replace_digit_with_letter(&2, &1))
      {holder, body <> IT.control_character(body)}
    end
  end

  @doc "A holder and a valid CURP for them."
  def mexican do
    gen all holder <- holder(),
            state <- member_of(~w(AS BC DF JC NL VZ YN)),
            digit <- integer(0..9),
            letter <- string(?A..?Z, length: 1) do
      date = holder.birth_date
      differentiator = if date.year < 2000, do: Integer.to_string(digit), else: letter
      sex = if holder.sex == :female, do: "M", else: "H"

      body =
        MX.name_code(holder) <>
          Calendar.strftime(date, "%y%m%d") <>
          sex <> state <> MX.consonant_code(holder) <> differentiator

      {holder, body <> Integer.to_string(MX.check_digit(body))}
    end
  end

  @doc "The document with the digit at one of `positions` changed."
  def mutate_digit(document, positions) do
    gen all position <- member_of(Enum.to_list(positions)), delta <- integer(1..9) do
      <<before::binary-size(^position), char, rest::binary>> = document
      before <> <<?0 + rem(char - ?0 + delta, 10)>> <> rest
    end
  end

  @doc "The document with the letter at `position` changed."
  def mutate_letter(document, position) do
    gen all delta <- integer(1..25) do
      <<before::binary-size(^position), char, rest::binary>> = document
      before <> <<?A + rem(char - ?A + delta, 26)>> <> rest
    end
  end

  defp name(examples),
    do: one_of([member_of(examples), string(?a..?z, min_length: 2, max_length: 10)])

  defp birth_date do
    first = ~D[1930-01-01]
    map(integer(0..Date.diff(~D[2007-12-31], first)), &Date.add(first, &1))
  end

  defp replace_digit_with_letter(body, position) do
    <<before::binary-size(^position), char, rest::binary>> = body
    letter = if char in ?0..?9, do: Enum.at(@omocodia, char - ?0), else: char
    before <> <<letter>> <> rest
  end
end
