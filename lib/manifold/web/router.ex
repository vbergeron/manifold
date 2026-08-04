defmodule Manifold.Web.Router do
  @moduledoc """
  The HTTP surface, served by Bandit. There is deliberately almost nothing here:
  `GET /socket` upgrades to `Manifold.Web.Socket` and everything real happens
  over that connection. `GET /health` reports the two sidecars so a browser or a
  script can check the app is up without speaking the protocol.
  """
  use Plug.Router

  plug :match
  plug :dispatch

  get "/socket" do
    conn
    |> WebSockAdapter.upgrade(Manifold.Web.Socket, [], timeout: 120_000)
    |> halt()
  end

  get "/health" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{ok: true, sidecars: Manifold.ready?()}))
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
