defmodule Fides.Origination.ApplicationRevision.Changes.HashContent do
  @moduledoc "Fingerprints a revision's declared terms, so equal terms give equal hashes."

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    terms = {
      Ash.Changeset.get_attribute(changeset, :amount_minor),
      Ash.Changeset.get_attribute(changeset, :monthly_income_minor)
    }

    hash = :crypto.hash(:sha256, :erlang.term_to_binary(terms, [:deterministic]))
    Ash.Changeset.force_change_attribute(changeset, :content_hash, hash)
  end
end
