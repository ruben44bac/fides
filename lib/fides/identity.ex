defmodule Fides.Identity do
  @moduledoc """
  Identity context: who a credit belongs to. It validates identity documents by
  country and keeps each holder once per document and country.
  """

  use Fides.Platform.Domain,
    boundary: [deps: [Fides.Platform], exports: []]

  require Ash.Query

  resources do
    resource Fides.Identity.DocumentType do
      define :list_document_types, action: :read
      define :seed_document_type, action: :seed
    end

    resource Fides.Identity.Person do
      define :resolve_person, action: :resolve
      define :get_person, action: :read, get_by: [:id]
    end

    resource Fides.Identity.Consent do
      define :accept_consent, action: :accept
      define :list_consents, action: :read
    end

    resource Fides.Identity.PiiAccessLog do
      define :record_pii_access, action: :record
      define :list_pii_accesses, action: :read
    end
  end

  @personal_fields [:name, :document, :email]

  @doc """
  Reveals one personal field of a holder to a member of staff, for a reason, and
  leaves who revealed what of whom, when and why in the access log. The row and the
  look are one transaction, and the reason is also the reason of the audited
  transaction: without a reason, nothing is revealed. The name comes back as one
  string.
  """
  @spec reveal(String.t(), Ecto.UUID.t(), :name | :document | :email, String.t() | nil, term()) ::
          {:ok, %{value: String.t(), access: Fides.Identity.PiiAccessLog.t()}} | {:error, term()}
  def reveal(country, person_id, field, reason, actor) when field in @personal_fields do
    look = fn -> look(country, person_id, field, reason, actor) end

    with_audit_reason(reason, fn ->
      Ash.transact([Fides.Identity.PiiAccessLog, Fides.Identity.Person], look)
    end)
  end

  # The row first: a refused row means no look
  defp look(country, person_id, field, reason, actor) do
    with {:ok, access} <-
           record_pii_access(
             %{subject_type: :person, subject_id: person_id, field: field, reason: reason},
             tenant: country,
             actor: actor
           ),
         {:ok, person} <-
           Ash.get(Fides.Identity.Person, person_id,
             tenant: country,
             authorize?: false,
             load: [field]
           ) do
      %{value: text(field, Map.fetch!(person, field)), access: access}
    end
  end

  @doc "The looks at a holder's personal data, newest first."
  @spec pii_accesses(String.t(), Ecto.UUID.t(), term()) :: {:ok, [struct()]} | {:error, term()}
  def pii_accesses(country, person_id, actor) do
    Fides.Identity.PiiAccessLog
    |> Ash.Query.filter(subject_type == :person and subject_id == ^person_id)
    |> Ash.Query.sort(accessed_at: :desc)
    |> Ash.read(tenant: country, actor: actor)
  end

  # The access log's reason becomes the reason of the audited transaction, when there
  # is one to carry it; a missing reason is for the record's validation to refuse
  defp with_audit_reason(reason, fun) when is_binary(reason) and reason != "" do
    case Fides.Platform.AuditContext.get() do
      nil -> fun.()
      _context -> Fides.Platform.AuditContext.run([reason: reason], fun)
    end
  end

  defp with_audit_reason(_reason, fun), do: fun.()

  defp text(:name, name) do
    [:given_names, :first_surname, :second_surname]
    |> Enum.map(&(Map.get(name, &1) || Map.get(name, Atom.to_string(&1))))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp text(_field, value), do: value

  @doc """
  The holder of a document in a country, or nil. Found by the document's keyed hash,
  so nothing is decrypted.
  """
  @spec holder_of_document(String.t(), String.t()) ::
          {:ok, Fides.Identity.Person.t() | nil} | {:error, term()}
  def holder_of_document(country, document) do
    hash = Fides.Platform.BlindIndex.document(country, document)

    Fides.Identity.Person
    |> Ash.Query.filter(document_hash == ^hash)
    |> Ash.read_one(tenant: country, authorize?: false)
  end

  @doc """
  What Intake finds about a holder: whether their document is still valid for the
  country with the name they keep, and, where the document encodes a birth date,
  whether they were verified as an adult. `adult?` is nil for documents that encode
  none.
  """
  @spec check_holder(String.t(), Ecto.UUID.t(), term()) ::
          {:ok,
           %{
             document_valid?: boolean(),
             adult?: boolean() | nil,
             adult_verified_at: DateTime.t() | nil
           }}
          | {:error, term()}
  def check_holder(country, person_id, actor) do
    with {:ok, person} <-
           Ash.get(Fides.Identity.Person, person_id,
             tenant: country,
             actor: actor,
             load: [:name, :document]
           ) do
      names = Map.new(person.name, fn {key, value} -> {name_key(key), value} end)
      type = person.document_type

      adult? =
        cond do
          person.adult_verified_at -> true
          Fides.Identity.Documents.encodes_birth_date?(country, type) -> false
          true -> nil
        end

      {:ok,
       %{
         document_valid?:
           Fides.Identity.Documents.revalidate(country, type, person.document, names) == :ok,
         adult?: adult?,
         adult_verified_at: person.adult_verified_at
       }}
    end
  end

  @doc "A holder's document type and document, for the agent that asks the bank provider with them."
  @spec holder_document(String.t(), Ecto.UUID.t(), term()) ::
          {:ok, %{document_type: String.t(), document: String.t()}} | {:error, term()}
  def holder_document(country, person_id, actor) do
    with {:ok, person} <-
           Ash.get(Fides.Identity.Person, person_id,
             tenant: country,
             actor: actor,
             load: [:document]
           ) do
      {:ok, %{document_type: person.document_type, document: person.document}}
    end
  end

  @doc "A holder's contact email, for the mail that sends them a notice."
  @spec holder_email(String.t(), Ecto.UUID.t(), term()) :: {:ok, String.t()} | {:error, term()}
  def holder_email(country, person_id, actor) do
    with {:ok, person} <-
           Ash.get(Fides.Identity.Person, person_id,
             tenant: country,
             actor: actor,
             load: [:email]
           ) do
      {:ok, person.email}
    end
  end

  @doc "Validates a document for a country, against the holder's data when the document encodes it."
  defdelegate validate_document(country, type, document, holder \\ %{}),
    to: Fides.Identity.Documents,
    as: :validate

  @doc "Whether someone born on `birth_date` is an adult on `today`."
  defdelegate adult?(birth_date, today), to: Fides.Identity.Documents

  @name_parts %{
    "given_names" => :given_names,
    "first_surname" => :first_surname,
    "second_surname" => :second_surname
  }

  # The name comes back with the keys it was stored with
  defp name_key(key) when is_atom(key), do: key
  defp name_key(key), do: Map.fetch!(@name_parts, key)
end
