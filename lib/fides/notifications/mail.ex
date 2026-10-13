defmodule Fides.Notifications.Mail do
  @moduledoc """
  Sends a notice by email. The address comes from Identity at the moment of sending,
  with the mail's own identity, so the notice and the notifier never hold it.
  """

  import Swoosh.Email

  alias Fides.Notifications.Templates
  alias Fides.Platform.AgentActor

  @spec send(struct()) :: {:ok, term()} | {:error, term()}
  def send(notification) do
    with {:ok, address} <-
           Fides.Identity.holder_email(
             notification.country_code,
             notification.person_id,
             AgentActor.new(:mailer)
           ) do
      {subject, body} =
        Templates.render(
          notification.template,
          notification.language,
          notification.application_id
        )

      new()
      |> to(address)
      |> from(Application.get_env(:fides, __MODULE__)[:from] || {"Fides", "no-reply@fides.test"})
      |> subject(subject)
      |> text_body(body)
      |> Fides.Platform.Mailer.deliver()
    end
  end
end
