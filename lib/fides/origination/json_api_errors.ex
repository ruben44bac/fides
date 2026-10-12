defmodule Fides.Origination.JsonApiErrors do
  @moduledoc """
  Answers invalid input with 422 Unprocessable Entity, each error pointing at its
  field, rather than AshJsonApi's 400. Malformed requests, such as an unreadable body
  or filter, keep their 400.

  AshJsonApi gives each detail as a template with its values in `meta`, such as
  "must be greater than or equal to %{min}"; the values are put in, so the detail
  reads whole.
  """

  @invalid_input ~w(invalid_attribute invalid_argument required invalid)

  @spec handle(AshJsonApi.Error.t(), map()) :: AshJsonApi.Error.t()
  def handle(error, _context), do: error |> status() |> fill_in()

  defp status(%{status_code: 400, code: code} = error) when code in @invalid_input,
    do: %{error | status_code: 422}

  defp status(error), do: error

  defp fill_in(%{detail: detail, meta: meta} = error) when is_binary(detail) and is_map(meta) do
    detail =
      Regex.replace(~r/%{(\w+)}/, detail, fn placeholder, name ->
        Enum.find_value(meta, placeholder, fn {key, value} ->
          to_string(key) == name && text(value)
        end)
      end)

    %{error | detail: detail}
  end

  defp fill_in(error), do: error

  defp text(value) when is_binary(value), do: value
  defp text(value) when is_atom(value) or is_number(value), do: to_string(value)
  defp text(values) when is_list(values), do: Enum.map_join(values, ", ", &text/1)
  defp text(value), do: inspect(value)
end
