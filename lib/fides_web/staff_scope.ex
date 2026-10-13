defmodule FidesWeb.StaffScope do
  @moduledoc """
  Who is using the backoffice and where they may work: the staff user, their global
  role if any, and the countries of their active scopes. Admins and auditors work in
  every country.
  """

  alias Fides.Platform.Actor

  @enforce_keys [:user, :global_role, :countries]
  defstruct [:user, :global_role, :countries]

  @type t :: %__MODULE__{
          user: struct(),
          global_role: :admin | :auditor | nil,
          countries: [String.t()]
        }

  @spec new(struct()) :: t()
  def new(user) do
    global_role = Actor.global_role(user)

    countries =
      if global_role,
        do: Fides.Countries.list_countries!() |> Enum.map(& &1.code) |> Enum.sort(),
        else: Actor.countries(user, [:analyst, :risk_manager]) |> Enum.sort()

    %__MODULE__{user: user, global_role: global_role, countries: countries}
  end

  @doc "The actor's role in a country, for what a screen offers."
  @spec role(t(), String.t()) :: :admin | :auditor | :analyst | :risk_manager | nil
  def role(%__MODULE__{global_role: role}, _country) when not is_nil(role), do: role
  def role(%__MODULE__{user: user}, country), do: Actor.country_role(user, country)
end
