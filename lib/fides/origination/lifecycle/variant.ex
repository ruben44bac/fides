defmodule Fides.Origination.Lifecycle.Variant do
  @moduledoc """
  What each country declares on top of the base life cycle: how its bank data
  arrives, whether a large approval needs a countersignature and, when the two do not
  cover it, transitions and effects of its own.

    * `:sync` bank data comes back with the request. `:async` bank data arrives
      later through the provider's signed webhook, so the application waits in
      `awaiting_bank_callback`.
    * With a countersignature, an analyst's approval above the threshold of the
      country's policy goes to `pending_countersign`, for a risk manager. Without
      it, the analyst's approval is final with any amount.
  """

  alias Fides.Origination.Lifecycle

  @doc "ISO 3166-1 alpha-2 code of the country."
  @callback country() :: String.t()

  @doc "How the country's bank data arrives."
  @callback bank_data() :: :sync | :async

  @doc "Whether an approval above the policy's threshold needs a risk manager's countersignature."
  @callback countersign?() :: boolean()

  @doc "Transitions of the country's own, as `{from, to, actors}` or `{from, to, actors, guard}`."
  @callback transitions() :: [tuple()]

  @doc "Effects of the country's own on entering a state; they replace the base effects of that state."
  @callback effects() :: %{atom() => [Lifecycle.effect()]}

  @optional_callbacks transitions: 0, effects: 0
end
