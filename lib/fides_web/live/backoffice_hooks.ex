defmodule FidesWeb.BackofficeHooks do
  @moduledoc """
  What every backoffice screen needs on mount: a signed-in staff user, as the scope
  the screen works in and as the actor its writes are audited as. Without one, the
  screen sends to the sign-in.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, redirect: 2]

  alias Fides.Platform.AuditContext

  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont | :halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:require_staff, _params, _session, socket) do
    case socket.assigns[:current_staff_user] do
      %{} = user ->
        # The screen's process lives as long as the screen, and so does its context
        AuditContext.put(actor: "staff_user:" <> user.id, reason: "backoffice")
        {:cont, assign(socket, :current_scope, FidesWeb.StaffScope.new(user))}

      _nobody ->
        {:halt,
         socket
         |> put_flash(:error, "Sign in to continue.")
         |> redirect(to: "/backoffice/sign-in")}
    end
  end
end
