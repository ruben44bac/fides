defmodule Fides.Risk.Engine.Inputs do
  @moduledoc """
  Everything a decision depends on, in canonical form. Financial and public data
  only: the engine never sees a name, a document number or an email.

    * Amounts are integers in minor units of the country's currency.
    * `declared_income_minor` is the monthly income the applicant declared, and
      `observed_income_minor` the monthly income the bank observed.
    * `income_months` counts the recent months with income, out of the last six.
    * `adult?` is nil when the document does not encode a birth date.
    * `previous_rejection_on` is the date of the holder's last rejection, if any.
  """

  @enforce_keys [
    :country,
    :amount_minor,
    :declared_income_minor,
    :observed_income_minor,
    :total_debt_minor,
    :score,
    :income_months,
    :document_valid?,
    :evaluated_on
  ]
  defstruct @enforce_keys ++ [adult?: nil, previous_rejection_on: nil]

  @type t :: %__MODULE__{
          country: String.t(),
          amount_minor: pos_integer(),
          declared_income_minor: integer(),
          observed_income_minor: non_neg_integer(),
          total_debt_minor: non_neg_integer(),
          score: non_neg_integer(),
          income_months: 0..6,
          document_valid?: boolean(),
          adult?: boolean() | nil,
          previous_rejection_on: Date.t() | nil,
          evaluated_on: Date.t()
        }
end
