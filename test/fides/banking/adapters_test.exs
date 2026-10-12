defmodule Fides.Banking.AdaptersTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Fides.Banking.Adapters
  alias Fides.Banking.Adapters.MxWebhook
  alias Fides.Banking.Adapters.Profile

  @fixtures Path.expand("../../fixtures/banking", __DIR__)

  @recorded [
    {"es_json", "es.json",
     %Profile{
       observed_income_minor: 250_000,
       total_debt_minor: 1_200_000,
       income_months: 6,
       score: 720,
       account_masked: "****1332"
     }},
    {"pt_json", "pt.json",
     %Profile{
       observed_income_minor: 250_000,
       total_debt_minor: 1_200_050,
       income_months: 6,
       score: 710,
       account_masked: "****0154"
     }},
    {"it_xml", "it.xml",
     %Profile{
       observed_income_minor: 250_000,
       total_debt_minor: 1_200_000,
       income_months: 6,
       score: 700,
       account_masked: "****3456"
     }},
    {"mx_webhook", "mx.json",
     %Profile{
       observed_income_minor: 3_000_050,
       total_debt_minor: 12_000_000,
       income_months: 6,
       score: 690,
       account_masked: "****7771"
     }},
    {"co_json", "co.json",
     %Profile{
       observed_income_minor: 450_000_000,
       total_debt_minor: 1_500_000_000,
       income_months: 6,
       score: 650,
       account_masked: "****8901"
     }},
    {"br_json", "br.json",
     %Profile{
       observed_income_minor: 850_000,
       total_debt_minor: 2_500_000,
       income_months: 6,
       score: 742,
       account_masked: "****4567"
     }}
  ]

  # Fields each adapter reads; the rest of the answer is not part of the profile
  @unused_paths [["event_id"], ["sequence"], ["request_id"], ["conta", "agencia"]]

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  @tag spec: "BANK-01"
  test "every provider's recorded answer becomes the normalized profile" do
    for {key, file, expected} <- @recorded do
      assert Adapters.parse(key, fixture(file)) == {:ok, expected}, key
    end
  end

  test "every seeded bank provider has an adapter" do
    adapters = Enum.map(Fides.Banking.Seeds.providers(), & &1.adapter)
    assert Enum.sort(adapters) == Enum.sort(Adapters.keys())
  end

  describe "malformed answers" do
    @tag spec: "BANK-07"
    test "an answer in another format is malformed, whatever the provider" do
      for {key, _file, _expected} <- @recorded do
        assert Adapters.parse(key, "not an answer") == {:error, {:malformed, :body}}, key
      end
    end

    @tag spec: "BANK-07"
    test "a missing or invalid field is malformed and named" do
      for {key, file, _expected} <- @recorded,
          key != "it_xml",
          answer = Jason.decode!(fixture(file)),
          path <- leaf_paths(answer) -- @unused_paths,
          mutation <- [:delete, :negative] do
        assert {:error, {:malformed, field}} =
                 Adapters.parse(key, Jason.encode!(mutate(answer, path, mutation))),
               "#{key} #{inspect(path)} #{mutation}"

        assert is_atom(field)
      end
    end

    @tag spec: "BANK-07"
    test "an Italian answer missing a field or with a negative value is malformed" do
      xml = fixture("it.xml")

      for element <- ~w(reddito_mensile debito_totale mesi_con_reddito punteggio iban) do
        without = Regex.replace(~r/\s*<#{element}[^>]*>[^<]*<\/#{element}>/, xml, "")
        negative = Regex.replace(~r/(<#{element}[^>]*>)[^<]*(<\/#{element}>)/, xml, "\\1-1\\2")

        assert {:error, {:malformed, _field}} = Adapters.parse("it_xml", without), element
        assert {:error, {:malformed, _field}} = Adapters.parse("it_xml", negative), element
      end
    end

    test "XML with a DTD or entities is refused, whatever its encoding" do
      external = """
      <?xml version="1.0"?>
      <!DOCTYPE profilo [<!ENTITY x SYSTEM "file:///etc/passwd">]>
      <profilo><iban>&x;</iban></profilo>
      """

      # A complete answer whose account comes from an entity
      internal = """
      <?xml version="1.0"?>
      <!DOCTYPE profilo [<!ENTITY acct "IT60X0542811101000000129999">]>
      <profilo>
        <reddito_mensile valuta="EUR">2500.00</reddito_mensile>
        <debito_totale valuta="EUR">12000.00</debito_totale>
        <mesi_con_reddito>6</mesi_con_reddito>
        <punteggio>700</punteggio>
        <iban>&acct;</iban>
      </profilo>
      """

      for xml <- [external, internal], body <- [xml | utf16(xml)] do
        assert Adapters.parse("it_xml", body) == {:error, {:malformed, :body}}
      end
    end

    test "XML that is not UTF-8 is malformed, never a crash" do
      xml = fixture("it.xml")

      utf32_le =
        <<0xFF, 0xFE, 0, 0>> <> :unicode.characters_to_binary(xml, :utf8, {:utf32, :little})

      utf32_be = <<0, 0, 0xFE, 0xFF>> <> :unicode.characters_to_binary(xml, :utf8, {:utf32, :big})

      for body <- [<<0xFF, 0xFE, 0, 0>>, <<0, 0, 0xFE, 0xFF>>, utf32_le, utf32_be | utf16(xml)] do
        assert Adapters.parse("it_xml", body) == {:error, {:malformed, :body}}
      end
    end

    test "an Italian field read twice is malformed, and only fields of <profilo> count" do
      xml = fixture("it.xml")

      twice =
        String.replace(
          xml,
          "<punteggio>700</punteggio>",
          "<punteggio>7</punteggio><punteggio>00</punteggio>"
        )

      nested =
        String.replace(xml, "</profilo>", "<storico><punteggio>0</punteggio></storico></profilo>")

      assert Adapters.parse("it_xml", twice) == {:error, {:malformed, :score}}
      assert {:ok, %Profile{score: 700}} = Adapters.parse("it_xml", nested)

      assert Adapters.parse("it_xml", String.replace(xml, "profilo>", "qualcosa>")) ==
               {:error, {:malformed, :observed_income_minor}}
    end

    test "answers over 64 KB and unknown adapters are refused" do
      assert Adapters.parse("es_json", String.duplicate(" ", 64 * 1024 + 1)) ==
               {:error, {:malformed, :body}}

      assert Adapters.parse("ar_json", "{}") == {:error, :unknown_adapter}
    end
  end

  describe "amounts" do
    property "Portuguese amounts with thousands dots and a decimal comma convert exactly" do
      check all minor <- integer(0..100_000_000_000) do
        text = thousands(div(minor, 100), ".") <> "," <> cents(minor)
        answer = %{Jason.decode!(fixture("pt.json")) | "rendimento_mensal" => text}

        assert {:ok, %{observed_income_minor: ^minor}} =
                 Adapters.parse("pt_json", Jason.encode!(answer))
      end
    end

    property "Italian amounts with a decimal point convert exactly" do
      check all minor <- integer(0..100_000_000_000) do
        text = "#{div(minor, 100)}.#{cents(minor)}"

        xml =
          Regex.replace(
            ~r/(<reddito_mensile[^>]*>)[^<]*/,
            fixture("it.xml"),
            "\\g{1}#{text}"
          )

        assert {:ok, %{observed_income_minor: ^minor}} = Adapters.parse("it_xml", xml)
      end
    end

    property "Mexican JSON numbers convert exactly, without floats" do
      check all minor <- integer(0..100_000_000_000) do
        body =
          String.replace(
            fixture("mx.json"),
            ~s("ingreso_mensual": 30000.50),
            ~s("ingreso_mensual": #{div(minor, 100)}.#{cents(minor)})
          )

        assert {:ok, %{observed_income_minor: ^minor}} = Adapters.parse("mx_webhook", body)
      end
    end

    test "Mexican amounts with more than two decimals are malformed" do
      body =
        String.replace(fixture("mx.json"), "30000.50", "30000.505")

      assert Adapters.parse("mx_webhook", body) ==
               {:error, {:malformed, :observed_income_minor}}
    end
  end

  @tag spec: "BANK-02"
  property "only the last four characters of an account survive" do
    check all account <- string(:alphanumeric, min_length: 4, max_length: 34) do
      answer = put_in(Jason.decode!(fixture("es.json")), ["cliente", "iban"], account)
      {:ok, profile} = Adapters.parse("es_json", Jason.encode!(answer))

      assert profile.account_masked == "****" <> String.slice(account, -4, 4)
    end
  end

  test "the Mexican webhook carries the event's identity" do
    assert MxWebhook.envelope(fixture("mx.json")) ==
             {:ok,
              %{
                event_id: "evt_01J9MX0000000000000000000",
                sequence: 3,
                request_id: "req_01J9MX0000000000000000000"
              }}

    assert MxWebhook.envelope(~s({"event_id": 1})) == {:error, {:malformed, :body}}
  end

  # The document in UTF-16, in both byte orders, with and without a BOM
  defp utf16(xml) do
    little = :unicode.characters_to_binary(xml, :utf8, {:utf16, :little})
    big = :unicode.characters_to_binary(xml, :utf8, {:utf16, :big})
    [little, <<0xFF, 0xFE>> <> little, big, <<0xFE, 0xFF>> <> big]
  end

  defp leaf_paths(%{} = map) do
    Enum.flat_map(map, fn {key, value} ->
      case value do
        %{} -> Enum.map(leaf_paths(value), &[key | &1])
        _leaf -> [[key]]
      end
    end)
  end

  defp mutate(answer, path, :delete), do: elem(pop_in(answer, path), 1)
  defp mutate(answer, path, :negative), do: put_in(answer, path, -1)

  defp cents(minor), do: minor |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")

  defp thousands(units, separator) do
    units
    |> Integer.to_string()
    |> String.reverse()
    |> String.to_charlist()
    |> Enum.chunk_every(3)
    |> Enum.map_join(separator, &List.to_string/1)
    |> String.reverse()
  end
end
