defmodule Fides.Identity.DocumentsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Fides.Identity.Documents
  alias Fides.Identity.Documents.IT
  alias Fides.Identity.Documents.MX
  alias Fides.Identity.Generators, as: G

  describe "Spain" do
    property "accepts every valid DNI and NIE" do
      check all dni <- G.dni(), nie <- G.nie() do
        assert {:ok, %{document: ^dni, birth_date: nil}} = Documents.validate("ES", "DNI", dni)
        assert {:ok, %{document: ^nie}} = Documents.validate("ES", "NIE", nie)
      end
    end

    property "rejects a DNI or NIE with one digit or the letter changed" do
      check all dni <- G.dni(),
                nie <- G.nie(),
                bad_dni <- one_of([G.mutate_digit(dni, 0..7), G.mutate_letter(dni, 8)]),
                bad_nie <- one_of([G.mutate_digit(nie, 1..7), G.mutate_letter(nie, 8)]) do
        assert {:error, _reasons} = Documents.validate("ES", "DNI", bad_dni)
        assert {:error, _reasons} = Documents.validate("ES", "NIE", bad_nie)
      end
    end
  end

  describe "Portugal" do
    property "accepts every valid NIF and rejects it with the check digit changed" do
      check all nif <- G.nif(), bad <- G.mutate_digit(nif, [8]) do
        assert {:ok, _result} = Documents.validate("PT", "NIF", nif)
        assert {:error, [:invalid_check_digit]} = Documents.validate("PT", "NIF", bad)
      end
    end
  end

  describe "Italy" do
    property "accepts every valid codice fiscale, omocodia included" do
      check all {holder, code} <- G.italian() do
        birth_date = holder.birth_date
        assert {:ok, %{birth_date: ^birth_date}} = Documents.validate("IT", "CF", code, holder)
      end
    end

    property "rejects a code that does not match the birth date, the sex or the names" do
      check all {holder, code} <- G.italian(),
                shift <- integer(1..400),
                other <- G.holder(),
                IT.surname_code(other) != IT.surname_code(holder) do
        later = %{holder | birth_date: Date.add(holder.birth_date, shift)}
        assert {:error, reasons} = Documents.validate("IT", "CF", code, later)
        assert :birth_date_mismatch in reasons

        flipped = %{holder | sex: if(holder.sex == :female, do: :male, else: :female)}
        assert {:error, reasons} = Documents.validate("IT", "CF", code, flipped)
        assert :sex_mismatch in reasons

        renamed = %{
          holder
          | first_surname: other.first_surname,
            second_surname: other.second_surname
        }

        assert {:error, reasons} = Documents.validate("IT", "CF", code, renamed)
        assert :name_mismatch in reasons
      end
    end

    property "rejects a code with the control character changed" do
      check all {holder, code} <- G.italian(), bad <- G.mutate_letter(code, 15) do
        assert {:error, [:invalid_check_character]} = Documents.validate("IT", "CF", bad, holder)
      end
    end

    test "matches a published example and needs the holder's data" do
      holder = [
        given_names: "Mario",
        first_surname: "Rossi",
        birth_date: ~D[1980-01-01],
        sex: :male
      ]

      assert {:ok, _result} = Documents.validate("IT", "CF", "RSSMRA80A01H501U", holder)
      assert {:error, [:missing_holder_data]} = Documents.validate("IT", "CF", "RSSMRA80A01H501U")
    end
  end

  describe "Mexico" do
    property "accepts every valid CURP and returns the birth date it encodes" do
      check all {holder, curp} <- G.mexican() do
        birth_date = holder.birth_date
        assert {:ok, %{birth_date: ^birth_date}} = Documents.validate("MX", "CURP", curp, holder)
      end
    end

    property "rejects a CURP with the check digit changed" do
      check all {holder, curp} <- G.mexican(), bad <- G.mutate_digit(curp, [17]) do
        assert {:error, [:invalid_check_digit]} = Documents.validate("MX", "CURP", bad, holder)
      end
    end

    property "rejects a CURP that does not match the birth date or the names" do
      check all {holder, curp} <- G.mexican(),
                shift <- integer(1..400),
                other <- G.holder(),
                MX.name_code(other) != MX.name_code(holder) do
        later = %{holder | birth_date: Date.add(holder.birth_date, shift)}
        assert {:error, [:birth_date_mismatch]} = Documents.validate("MX", "CURP", curp, later)

        renamed = %{other | birth_date: holder.birth_date, sex: holder.sex}
        assert {:error, [:name_mismatch]} = Documents.validate("MX", "CURP", curp, renamed)
      end
    end

    test "matches a published example" do
      holder = [
        given_names: "Gloria",
        first_surname: "Hernández",
        second_surname: "García",
        birth_date: ~D[1956-04-27],
        sex: :female
      ]

      assert {:ok, _result} = Documents.validate("MX", "CURP", "HEGG560427MVZRRL04", holder)

      assert {:error, [:sex_mismatch]} =
               Documents.validate(
                 "MX",
                 "CURP",
                 "HEGG560427MVZRRL04",
                 Keyword.put(holder, :sex, :male)
               )
    end

    test "follows the official name rules" do
      assert MX.name_code(%{
               first_surname: "De la Cruz",
               second_surname: "Núñez",
               given_names: "Ana"
             }) ==
               "CUNA"

      assert MX.name_code(%{
               first_surname: "López",
               second_surname: nil,
               given_names: "María Fernanda"
             }) ==
               "LOXF"

      # P-U-T-O spells an offensive word, so its second letter becomes X
      assert MX.name_code(%{
               first_surname: "Pulido",
               second_surname: "Torres",
               given_names: "Óscar"
             }) ==
               "PXTO"
    end
  end

  describe "Colombia" do
    property "accepts six to ten digits and rejects any other format" do
      check all cedula <- G.cedula(),
                short <- G.digits(5),
                long <- G.digits(11),
                letter <- string(?A..?Z, length: 1) do
        assert {:ok, _result} = Documents.validate("CO", "CC", cedula)
        assert {:error, [:invalid_format]} = Documents.validate("CO", "CC", short)
        assert {:error, [:invalid_format]} = Documents.validate("CO", "CC", long)
        assert {:error, [:invalid_format]} = Documents.validate("CO", "CC", cedula <> letter)
      end
    end
  end

  describe "Brazil" do
    property "accepts every valid CPF and rejects it with a check digit changed" do
      check all cpf <- G.cpf(), bad <- G.mutate_digit(cpf, [9, 10]) do
        assert {:ok, _result} = Documents.validate("BR", "CPF", cpf)
        assert {:error, [:invalid_check_digit]} = Documents.validate("BR", "CPF", bad)
      end
    end

    test "rejects repeated sequences" do
      for digit <- ?0..?9 do
        assert {:error, [:repeated_digits]} =
                 Documents.validate("BR", "CPF", String.duplicate(<<digit>>, 11))
      end
    end
  end

  describe "checking a stored holder again" do
    property "a valid CURP or codice fiscale checks again with the holder's names alone" do
      check all {mexican, curp} <- G.mexican(), {italian, code} <- G.italian() do
        assert Documents.revalidate("MX", "CURP", curp, names(mexican)) == :ok
        assert Documents.revalidate("IT", "CF", code, names(italian)) == :ok
      end
    end

    property "and not with someone else's names" do
      check all {holder, curp} <- G.mexican(),
                other <- G.holder(),
                MX.name_code(other) != MX.name_code(holder) do
        assert {:error, [:name_mismatch]} = Documents.revalidate("MX", "CURP", curp, names(other))
      end
    end

    test "documents that encode no birth date check again as they are" do
      names = %{given_names: "Ana", first_surname: "Ruiz"}

      assert Documents.revalidate("ES", "DNI", "12345678Z", names) == :ok

      assert {:error, [:invalid_check_character]} =
               Documents.revalidate("ES", "DNI", "12345678A", names)

      assert Documents.encodes_birth_date?("MX", "CURP")
      assert Documents.encodes_birth_date?("IT", "CF")
      refute Documents.encodes_birth_date?("ES", "DNI")
      refute Documents.encodes_birth_date?("AR", "DNI")
    end
  end

  defp names(holder), do: Map.take(holder, [:given_names, :first_surname, :second_surname])

  test "normalizes case, spaces, dots and dashes" do
    assert {:ok, %{document: "52998224725"}} = Documents.validate("BR", "CPF", " 529.982.247-25 ")
    assert {:ok, %{document: "12345678Z"}} = Documents.validate("ES", "DNI", "12345678-z")
  end

  test "rejects unknown countries and document types" do
    assert {:error, [:unsupported_country]} = Documents.validate("AR", "DNI", "12345678")
    assert {:error, [:unsupported_document_type]} = Documents.validate("ES", "CPF", "12345678Z")
    assert {:error, [:invalid_format]} = Documents.validate("ES", "DNI", nil)
    assert Documents.document_types("ES") == ["DNI", "NIE"]
    assert Documents.document_types("AR") == []
    assert Documents.countries() == ["ES", "PT", "IT", "MX", "CO", "BR"]
  end

  test "an adult is 18 or older on the given day" do
    assert Documents.adult?(~D[2008-10-11], ~D[2026-10-11])
    refute Documents.adult?(~D[2008-10-12], ~D[2026-10-11])
    assert Documents.adult?(~D[2008-02-29], ~D[2026-02-28])
  end

  test "the Identity context validates through its public functions" do
    assert {:ok, _result} = Fides.Identity.validate_document("ES", "DNI", "12345678Z")
    assert Fides.Identity.adult?(~D[1990-01-01], ~D[2026-10-11])
  end
end
