defmodule Fides.Identity.Documents.Samples do
  @moduledoc """
  Synthetic documents with valid check characters, for demos and tests. They name no
  real person: the numbers are made up, and the holders they are built for are
  fictitious.
  """

  alias Fides.Identity.Documents.ES
  alias Fides.Identity.Documents.MX

  @doc "A Spanish DNI for a number: its last eight digits and their control letter."
  @spec dni(non_neg_integer()) :: String.t()
  def dni(number) do
    digits = number |> rem(100_000_000) |> Integer.to_string() |> String.pad_leading(8, "0")
    digits <> ES.control_letter(digits)
  end

  @doc """
  A Mexican CURP for a holder with `given_names`, `first_surname`, `second_surname`,
  `birth_date` and `sex`, as if registered in Veracruz. The holder must be born in the
  twentieth century: later births take a letter where this one puts a digit.
  """
  @spec curp(map()) :: String.t()
  def curp(%{birth_date: %Date{year: year} = birth_date, sex: sex} = holder)
      when year in 1900..1999 do
    date =
      Enum.map_join([rem(year, 100), birth_date.month, birth_date.day], fn part ->
        part |> Integer.to_string() |> String.pad_leading(2, "0")
      end)

    body =
      MX.name_code(holder) <>
        date <> if(sex == :female, do: "M", else: "H") <> "VZ" <> MX.consonant_code(holder) <> "0"

    body <> Integer.to_string(MX.check_digit(body))
  end
end
