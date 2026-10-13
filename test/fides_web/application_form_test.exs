defmodule FidesWeb.ApplicationFormTest do
  use ExUnit.Case, async: true

  alias FidesWeb.ApplicationForm

  @catalog %{
    "ES" => %{currency: "EUR", document_types: ["DNI", "NIE"]},
    "MX" => %{currency: "MXN", document_types: ["CURP"]}
  }
  @version "2026-10"
  @spanish %{
    "country" => "ES",
    "amount" => "25000",
    "monthly_income" => "2500.50",
    "given_names" => "Lucía",
    "first_surname" => "Martín",
    "second_surname" => "",
    "document_type" => "DNI",
    "document" => "12345678Z",
    "email" => "lucia@example.com",
    "consent" => "true"
  }
  @mexican %{
    "country" => "MX",
    "amount" => "100000",
    "monthly_income" => "30000",
    "given_names" => "Gloria",
    "first_surname" => "Hernández",
    "second_surname" => "García",
    "document_type" => "CURP",
    "document" => "HEGG560427MVZRRL04",
    "email" => "gloria@example.com",
    "birth_date" => "1956-04-27",
    "consent" => "true"
  }

  defp errors(params) do
    {:error, errors} = ApplicationForm.cast(params, @catalog, @version)
    errors
  end

  defp fields(params), do: params |> errors() |> Keyword.keys() |> Enum.sort()

  test "turns what was typed into the submission the action takes" do
    assert {:ok, "ES", submission} = ApplicationForm.cast(@spanish, @catalog, @version)

    assert %{
             amount_minor: 2_500_000,
             monthly_income_minor: 250_050,
             currency: "EUR",
             channel: :form,
             consent_text_version: "2026-10",
             holder: holder
           } = submission

    assert holder == %{
             document_type: "DNI",
             document: "12345678Z",
             given_names: "Lucía",
             first_surname: "Martín",
             email: "lucia@example.com"
           }

    assert {:ok, "MX", %{currency: "MXN", holder: %{birth_date: ~D[1956-04-27]}}} =
             ApplicationForm.cast(@mexican, @catalog, @version)
  end

  test "amounts take a dot or a comma for the cents, and must be more than zero" do
    for {typed, minor} <- [{"25000", 2_500_000}, {"25000,5", 2_500_050}, {"0.99", 99}] do
      assert {:ok, _country, %{amount_minor: ^minor}} =
               ApplicationForm.cast(%{@spanish | "amount" => typed}, @catalog, @version)
    end

    assert [amount: {"must be more than zero", []}] = errors(%{@spanish | "amount" => "0"})

    assert [amount: {"must be an amount" <> _, []}] =
             errors(%{@spanish | "amount" => "25.000,00"})

    assert [monthly_income: {"is required", []}] = errors(%{@spanish | "monthly_income" => " "})
  end

  test "requires the holder's data, a document of the country, and the consent" do
    blank = Map.new(@spanish, fn {key, _value} -> {key, ""} end)

    assert fields(blank) == [
             :amount,
             :consent,
             :country,
             :document,
             :document_type,
             :email,
             :first_surname,
             :given_names,
             :monthly_income
           ]

    assert [document_type: {"is not a document of ES", []}] =
             errors(%{@spanish | "document_type" => "CURP"})

    assert [consent: {"must be confirmed", []}] = errors(%{@spanish | "consent" => "false"})
  end

  test "checks the document the way the action will" do
    assert [document: {"is not valid: invalid check character", []}] =
             errors(%{@spanish | "document" => "12345678A"})

    assert [document: {"is not valid: name mismatch", []}] =
             errors(%{@mexican | "given_names" => "Pedro"})

    # A document is not checked while what it is checked against is missing
    assert fields(%{@spanish | "first_surname" => "", "document" => "12345678A"}) ==
             [:first_surname]
  end

  test "asks for the data a document is checked against" do
    assert ApplicationForm.needed("ES", "DNI") == []
    assert ApplicationForm.needed("MX", "CURP") == [:birth_date]
    assert ApplicationForm.needed("IT", "CF") == [:birth_date, :sex]
    assert ApplicationForm.needed(nil, nil) == []

    assert [birth_date: {"is required for a CURP", []}] =
             errors(Map.delete(@mexican, "birth_date"))

    assert [birth_date: {"must be a date", []}] =
             errors(%{@mexican | "birth_date" => "27/04/1956"})

    assert [sex: {"is not one of the options", []}] = errors(Map.put(@spanish, "sex", "other"))
  end

  test "reads the action's errors back onto the form's fields" do
    refused =
      Ash.Error.to_error_class([
        Ash.Error.Changes.InvalidAttribute.exception(
          field: :amount_minor,
          message: "must be greater than or equal to %{min}",
          vars: [min: 1]
        ),
        Ash.Error.Changes.InvalidAttribute.exception(
          field: :person_id,
          message: "already has an application in progress"
        ),
        Ash.Error.Changes.InvalidArgument.exception(
          field: :email,
          path: [:holder],
          message: "field must be present"
        ),
        Ash.Error.Changes.InvalidAttribute.exception(
          field: :document,
          message: "is not valid: invalid_check_character"
        )
      ])

    assert ApplicationForm.errors_from(refused) == [
             amount: {"must be greater than or equal to %{min}", [min: 1]},
             holder: {"already has an application in progress", []},
             email: {"field must be present", []},
             document: {"is not valid: invalid check character", []}
           ]
  end
end
