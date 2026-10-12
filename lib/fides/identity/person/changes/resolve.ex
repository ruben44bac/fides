defmodule Fides.Identity.Person.Changes.Resolve do
  @moduledoc false
  # Validates the document for the tenant's country, then sets the encrypted values
  # and the keyed hashes. The birth date and the sex are only used for the check, and
  # to record that a holder whose document encodes an adult birth date is an adult.

  use Ash.Resource.Change

  alias Fides.Identity.Documents
  alias Fides.Platform.BlindIndex

  @holder_fields [:given_names, :first_surname, :second_surname, :birth_date, :sex]

  @impl true
  def change(changeset, _opts, _context) do
    country = changeset.to_tenant || changeset.tenant
    arguments = changeset.arguments
    holder = Map.take(arguments, @holder_fields)
    email = String.trim(arguments.email || "")

    with {:ok, %{document: document, birth_date: birth_date}} <-
           Documents.validate(country, arguments.document_type, arguments.document, holder),
         true <- email =~ ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/ || {:error, :email} do
      changeset
      |> Ash.Changeset.force_change_attribute(:document_type, arguments.document_type)
      |> Ash.Changeset.force_change_attribute(
        :document_hash,
        BlindIndex.document(country, document)
      )
      |> Ash.Changeset.force_change_attribute(:email_hash, BlindIndex.email(email))
      |> AshCloak.encrypt_and_set(:document, document)
      |> AshCloak.encrypt_and_set(:email, email)
      |> AshCloak.encrypt_and_set(
        :name,
        Map.take(holder, [:given_names, :first_surname, :second_surname])
      )
      |> verify_adult(birth_date)
    else
      {:error, :email} ->
        Ash.Changeset.add_error(changeset, field: :email, message: "is not a valid email")

      {:error, reasons} ->
        Ash.Changeset.add_error(changeset,
          field: :document,
          message: "is not valid: #{Enum.join(reasons, ", ")}"
        )
    end
  end

  # Only a birth date the document encodes, checked against the holder's data, proves
  # adulthood
  defp verify_adult(changeset, nil), do: changeset

  defp verify_adult(changeset, birth_date) do
    if Documents.adult?(birth_date, Date.utc_today()),
      do: Ash.Changeset.force_change_attribute(changeset, :adult_verified_at, DateTime.utc_now()),
      else: changeset
  end
end
