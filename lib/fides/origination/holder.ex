defmodule Fides.Origination.Holder do
  @moduledoc """
  The holder's document and data as a submission carries them. Identity checks them
  against each other: some documents encode the name, the birth date or the sex.
  """

  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        document_type: [type: :string, allow_nil?: false],
        document: [type: :string, allow_nil?: false],
        given_names: [type: :string, allow_nil?: false],
        first_surname: [type: :string, allow_nil?: false],
        second_surname: [type: :string],
        email: [type: :string, allow_nil?: false],
        birth_date: [type: :date],
        sex: [type: :atom, constraints: [one_of: [:female, :male]]]
      ]
    ]
end
