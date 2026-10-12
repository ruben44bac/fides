defmodule Fides.Banking.Adapters.ItXml do
  @moduledoc """
  Italy's provider: UTF-8 XML with amounts as text with a decimal point.

      <profilo>
        <reddito_mensile valuta="EUR">2500.00</reddito_mensile>
        <debito_totale valuta="EUR">12000.00</debito_totale>
        <mesi_con_reddito>6</mesi_con_reddito>
        <punteggio>700</punteggio>
        <iban>IT60...</iban>
      </profilo>

  Only the direct children of `<profilo>` are read, and a field that appears twice
  is malformed. Documents with a DTD or entity declarations are refused: the
  provider never sends them, and they are how external-entity and entity-expansion
  attacks arrive. The parser refuses entities too. Element names stay strings, so
  no atom is ever created from input.
  """

  @behaviour Fides.Banking.Adapters.Adapter

  import Fides.Banking.Adapters.Values

  alias Fides.Banking.Adapters.Profile

  @separators [decimal: ".", thousands: ","]

  @impl true
  def key, do: "it_xml"

  @impl true
  def parse(body) do
    with :ok <- refuse_declarations(body),
         {:ok, fields} <- profile_fields(body) do
      Profile.build(
        observed_income_minor: amount(fields["reddito_mensile"], @separators),
        total_debt_minor: amount(fields["debito_totale"], @separators),
        income_months: integer(fields["mesi_con_reddito"]),
        score: integer(fields["punteggio"]),
        account_masked: mask(fields["iban"])
      )
    end
  end

  # XML forbids NUL characters, and every UTF-16 or UTF-32 document has NUL bytes,
  # so a document this search could miss never reaches the parser
  defp refuse_declarations(body) do
    if String.contains?(body, [<<0>>, "<!DOCTYPE", "<!ENTITY"]),
      do: {:error, {:malformed, :body}},
      else: :ok
  end

  # The text of each element directly under <profilo>, keyed by its name
  defp profile_fields(body) do
    collect = fn
      {:startElement, _uri, name, _qualified, _attributes}, _location, {path, fields} ->
        name = List.to_string(name)
        {[name | path], start_field(fields, path, name)}

      {:characters, chars}, _location, {[name, "profilo"] = path, fields} ->
        {path, Map.update!(fields, name, &append(&1, chars))}

      {:endElement, _uri, _name, _qualified}, _location, {[_current | path], fields} ->
        {path, fields}

      _event, _location, state ->
        state
    end

    options = [:disallow_entities, event_fun: collect, event_state: {[], %{}}]

    case :xmerl_sax_parser.stream(body, options) do
      {:ok, {_path, fields}, _rest} -> {:ok, Map.new(fields, &trim/1)}
      _error -> {:error, {:malformed, :body}}
    end
  end

  # A field that appears twice is kept as :duplicate, which no conversion accepts
  defp start_field(fields, ["profilo"], name),
    do: Map.update(fields, name, "", fn _first -> :duplicate end)

  defp start_field(fields, _path, _name), do: fields

  defp append(:duplicate, _chars), do: :duplicate
  defp append(text, chars), do: text <> List.to_string(chars)

  defp trim({name, :duplicate}), do: {name, :duplicate}
  defp trim({name, text}), do: {name, String.trim(text)}
end
