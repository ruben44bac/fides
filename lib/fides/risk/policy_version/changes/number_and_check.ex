defmodule Fides.Risk.PolicyVersion.Changes.NumberAndCheck do
  @moduledoc """
  Checks the proposed thresholds against the country's policy, and numbers the
  version after the country's last one. Two proposals at the same time cannot take
  the same number: the second fails on the unique version.
  """

  use Ash.Resource.Change

  alias Fides.Risk.Engine

  @impl true
  def change(changeset, _opts, _context) do
    params = Ash.Changeset.get_attribute(changeset, :params)

    case Engine.cast_params(changeset.tenant, params) do
      {:ok, params} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:params, params)
        |> Ash.Changeset.before_action(&number/1)

      {:error, message} ->
        Ash.Changeset.add_error(changeset, field: :params, message: message)
    end
  end

  defp number(changeset) do
    last =
      Ash.max!(changeset.resource, :version, tenant: changeset.tenant, authorize?: false) || 0

    Ash.Changeset.force_change_attribute(changeset, :version, last + 1)
  end
end
