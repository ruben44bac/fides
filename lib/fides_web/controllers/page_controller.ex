defmodule FidesWeb.PageController do
  use FidesWeb, :controller

  def home(conn, _params), do: redirect(conn, to: ~p"/backoffice")
end
