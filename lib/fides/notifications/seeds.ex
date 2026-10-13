defmodule Fides.Notifications.Seeds do
  @moduledoc """
  Registers the receiver a demo delivers its webhooks to, when one is configured: the
  mocks app's receiver in development. A receiver already registered is left as it is.
  """

  require Ash.Query

  alias Fides.Platform.AuditContext
  alias Fides.Platform.SystemActor

  @spec run() :: Fides.Notifications.WebhookEndpoint.t() | nil
  def run do
    case Application.get_env(:fides, __MODULE__) do
      nil ->
        nil

      config ->
        register(Keyword.fetch!(config, :receiver_url), Keyword.fetch!(config, :receiver_secret))
    end
  end

  defp register(url, secret) do
    actor = SystemActor.new(:seeds)
    opts = [actor: actor]

    existing =
      Fides.Notifications.WebhookEndpoint
      |> Ash.Query.filter(url == ^url)
      |> Ash.read_one!(opts)

    existing ||
      AuditContext.run(
        [actor: SystemActor.audit_id(actor), reason: "seed the demo receiver"],
        fn ->
          Fides.Notifications.register_endpoint!(
            %{
              name: "Demo receiver",
              url: url,
              secret: secret,
              events: [:info_requested, :approved, :rejected]
            },
            opts
          )
        end
      )
  end
end
