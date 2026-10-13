defmodule Fides.Notifications.Event do
  @moduledoc """
  What Fides tells other systems about a change: the event's id and type, when it
  happened, the application and its country, the state it entered and the reason codes
  behind it. Nothing about the holder. The same change always gives the same event,
  so announcing it twice delivers it once.
  """

  @spec id(struct(), atom()) :: String.t()
  def id(application, event) do
    digest = :crypto.hash(:sha256, "#{application.id}:#{application.lock_version}:#{event}")
    "evt_" <> (digest |> Base.url_encode64(padding: false) |> binary_part(0, 22))
  end

  @spec payload(struct(), atom(), [atom() | String.t()]) :: %{String.t() => term()}
  def payload(application, event, reason_codes) do
    %{
      "event_id" => id(application, event),
      "type" => "application.#{event}",
      "occurred_at" => DateTime.to_iso8601(application.updated_at),
      "application_id" => application.id,
      "country" => application.country_code,
      "state" => Atom.to_string(application.state),
      "lock_version" => application.lock_version,
      "reason_codes" => Enum.map(reason_codes, &to_string/1)
    }
  end

  @doc "The body as it is signed and sent."
  @spec body(map()) :: String.t()
  def body(payload), do: Jason.encode!(payload)
end
