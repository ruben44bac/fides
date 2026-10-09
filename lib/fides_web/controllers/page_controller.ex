defmodule FidesWeb.PageController do
  use FidesWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
