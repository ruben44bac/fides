defmodule Fides.Origination.ApplicationCommands do
  @moduledoc """
  The commands on credit applications as the API takes them: the application by its
  id, the inputs in the request's body. Each command finds the application among those
  the actor may see, so one outside the actor's countries does not exist for them, and
  then runs the application's own action: the same policies, checks and evidence apply
  as anywhere else. Commands answer with the application as it stands afterwards.
  """

  use Fides.Platform.Resource,
    domain: Fides.Origination,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshJsonApi.Resource]

  alias Fides.Origination.ApplicationCommands.Run
  alias Fides.Origination.CreditApplication
  alias Fides.Origination.Lifecycle
  alias Fides.Platform.Types.CountryCode

  json_api do
    type "application_command"

    routes do
      base "/applications"
      route :post, "/", :submit
      route :post, "/search", :search
      route :get, "/:id/transitions", :transitions
      route :post, "/:id/transitions", :transition
      route :post, "/:id/revisions", :revise
      route :post, "/:id/reapply", :reapply
    end
  end

  actions do
    action :submit, :struct do
      description "Submits an application in a country for its holder, with their consent."
      constraints instance_of: CreditApplication
      argument :country_code, CountryCode, allow_nil?: false
      argument :amount_minor, :integer, allow_nil?: false
      argument :monthly_income_minor, :integer, allow_nil?: false
      argument :currency, :string, allow_nil?: false
      argument :channel, :atom, default: :api, constraints: [one_of: [:api, :form, :chat]]
      argument :holder, Fides.Origination.Holder, allow_nil?: false, sensitive?: true
      argument :consent_text_version, :string, allow_nil?: false
      run {Run, command: :submit}
    end

    action :search, :map do
      description """
      The applications of a document's holder in a country, newest first, a page at a
      time. The document travels in the body, so it never reaches a URL or a log.
      """

      constraints fields: [
                    data: [
                      type: {:array, :struct},
                      constraints: [items: [instance_of: CreditApplication]]
                    ],
                    next: [type: :string, description: "Cursor of the next page, if any."]
                  ]

      argument :country_code, CountryCode, allow_nil?: false
      argument :document, :string, allow_nil?: false, sensitive?: true
      argument :state, :atom, constraints: [one_of: Lifecycle.states()]
      argument :submitted_from, :utc_datetime_usec
      argument :submitted_until, :utc_datetime_usec
      argument :min_amount_minor, :integer
      argument :max_amount_minor, :integer
      argument :after, :string, description: "The cursor of the previous page."
      argument :limit, :integer, default: 25, constraints: [min: 1, max: 100]
      run {Run, command: :search}
    end

    action :transitions, :map do
      description "The states the actor may move the application to now, and its current version."

      constraints fields: [
                    state: [type: :atom],
                    lock_version: [type: :integer],
                    transitions: [type: {:array, :atom}]
                  ]

      argument :id, :uuid, allow_nil?: false
      run {Run, command: :transitions}
    end

    action :transition, :struct do
      description """
      Moves the application to another state. A person gives a reason, and the move
      fails without changes when the application is no longer in `expected_version`.
      """

      constraints instance_of: CreditApplication
      argument :id, :uuid, allow_nil?: false
      argument :to, :atom, allow_nil?: false, constraints: [one_of: Lifecycle.states()]
      argument :reason, :string
      argument :expected_version, :integer, allow_nil?: false
      run {Run, command: :transition}
    end

    action :revise, :struct do
      description """
      Answers a request for information with the corrected terms, which become the
      next revision; the application goes back to validation.
      """

      constraints instance_of: CreditApplication
      argument :id, :uuid, allow_nil?: false
      argument :amount_minor, :integer, allow_nil?: false
      argument :monthly_income_minor, :integer, allow_nil?: false
      argument :expected_version, :integer, allow_nil?: false
      run {Run, command: :revise}
    end

    action :reapply, :struct do
      description """
      Retries a rejected or cancelled application as a new one of the same holder,
      with new terms and consent.
      """

      constraints instance_of: CreditApplication
      argument :id, :uuid, allow_nil?: false
      argument :amount_minor, :integer, allow_nil?: false
      argument :monthly_income_minor, :integer, allow_nil?: false
      argument :channel, :atom, default: :api, constraints: [one_of: [:api, :form, :chat]]
      argument :consent_text_version, :string, allow_nil?: false
      run {Run, command: :reapply}
    end
  end

  # Each command runs the application's own action, which authorizes the actor
  policies do
    policy action_type(:action) do
      authorize_if always()
    end
  end
end
