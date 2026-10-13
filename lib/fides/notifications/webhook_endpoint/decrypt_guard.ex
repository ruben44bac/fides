defmodule Fides.Notifications.WebhookEndpoint.DecryptGuard do
  @moduledoc """
  Decides who may decrypt a receiver's secret: only a delivery, to sign what it sends,
  which asks for it in the load's context.
  """

  @spec approve(module(), [struct()], atom(), map()) :: :ok | {:error, String.t()}
  def approve(_resource, _records, :secret, %{source_context: %{fides: %{decrypt: :deliver}}}),
    do: :ok

  def approve(_resource, _records, field, _context),
    do: {:error, "#{field} is only decrypted to sign a delivery"}
end
