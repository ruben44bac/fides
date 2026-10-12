defmodule Fides.Identity.Documents.Holder do
  @moduledoc """
  The holder's data a document is checked against: given names, surnames, birth
  date and sex. Documents such as the Italian codice fiscale or the Mexican CURP
  encode them; the rest ignore them.
  """

  defstruct [:given_names, :first_surname, :second_surname, :birth_date, :sex]

  @type t :: %__MODULE__{
          given_names: String.t() | nil,
          first_surname: String.t() | nil,
          second_surname: String.t() | nil,
          birth_date: Date.t() | nil,
          sex: :female | :male | nil
        }

  @spec new(t() | map() | keyword()) :: t()
  def new(%__MODULE__{} = holder), do: holder
  def new(fields), do: struct(__MODULE__, Map.new(fields))
end
