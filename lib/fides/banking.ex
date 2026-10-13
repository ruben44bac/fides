defmodule Fides.Banking do
  @moduledoc """
  Banking context: each country's bank data provider, with its own format behind an
  anti-corruption layer, so the rest of Fides only sees a normalized, masked profile.
  """

  use Fides.Platform.Domain,
    boundary: [deps: [Fides.Platform, Fides.Notifications, Jason, Decimal], exports: []]

  resources do
    resource Fides.Banking.BankProvider do
      define :list_bank_providers, action: :read
      define :seed_bank_provider, action: :seed
    end

    resource Fides.Banking.ProviderExchange do
      define :record_provider_exchange, action: :record
      define :list_provider_exchanges, action: :read
    end

    resource Fides.Banking.BankProfile do
      define :record_bank_profile, action: :record
      define :list_bank_profiles, action: :read
      define :get_bank_profile, action: :read, get_by: [:id]
    end
  end

  @doc """
  Asks the country's bank provider for the profile of a holder's document, for an
  application. A synchronous provider answers with the profile, kept normalized and
  masked; an asynchronous one accepts the request, to answer later. Every call leaves
  an exchange, and calling again with the same request id asks the provider the same.
  """
  @spec fetch_profile(
          String.t(),
          Ecto.UUID.t(),
          %{document_type: String.t(), document: String.t()},
          String.t(),
          term()
        ) :: {:ok, Fides.Banking.BankProfile.t()} | {:accepted, String.t()} | {:error, String.t()}
  defdelegate fetch_profile(country, application_id, holder, request_id, actor),
    to: Fides.Banking.Fetch,
    as: :run

  @doc "Checks and reads a provider's answer delivered through its signed webhook."
  defdelegate verify_callback(country, signature, body, now \\ System.os_time(:second)),
    to: Fides.Banking.Callback,
    as: :verify

  @doc "The event's identity in a provider's delivery, as far as the body allows."
  defdelegate callback_envelope(provider, body), to: Fides.Banking.Callback, as: :envelope

  @doc "The call to a provider still waiting for its answer, by the request id the answer names."
  @spec pending_exchange(String.t(), String.t(), term()) ::
          {:ok, Fides.Banking.ProviderExchange.t() | nil} | {:error, term()}
  def pending_exchange(country, request_id, actor) do
    require Ash.Query

    Fides.Banking.ProviderExchange
    |> Ash.Query.filter(request_id == ^request_id and status == :pending)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(tenant: country, actor: actor)
  end
end
