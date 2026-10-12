defmodule Fides.Platform.Context do
  @moduledoc """
  Maps a module to its context root (`Fides.<Context>`) by name alone, without
  loading it, so compile-time checks never wait on other modules.
  """

  @contexts ~w(Origination Risk Identity Banking Review Orchestration Knowledge AI
               Notifications Audit Accounts Countries)

  @spec of(module() | nil) :: module() | nil
  def of(module) when is_atom(module) and not is_nil(module) do
    case Atom.to_string(module) do
      "Elixir.Fides." <> _ ->
        case Module.split(module) do
          ["Fides", context | _] when context in @contexts -> Module.concat(["Fides", context])
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def of(_), do: nil
end
