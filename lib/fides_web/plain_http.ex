defmodule FidesWeb.PlainHttp do
  @moduledoc """
  Which hosts a production node answers over plain HTTP instead of redirecting to
  HTTPS: those named in `FIDES_PLAIN_HTTP_HOSTS`, such as the service name the mocks
  call inside compose or a cluster, where no proxy terminates TLS. Browsers on
  localhost and the health check are always answered as they come.
  """

  @doc "Whether the request's host is one that is answered over plain HTTP."
  @spec allowed?(Plug.Conn.t()) :: boolean()
  def allowed?(%Plug.Conn{host: host}),
    do: host in Application.get_env(:fides, :plain_http_hosts, [])
end
