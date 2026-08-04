defmodule Manifold.Web.Router do
  @moduledoc """
  The HTTP surface, served by Bandit. There is deliberately almost nothing here:
  `GET /socket` upgrades to `Manifold.Web.Socket` and everything real happens
  over that connection. `GET /health` reports the two sidecars so a browser or a
  script can check the app is up without speaking the protocol.

  It also serves the built UI (`GET /` plus its assets), so the whole application
  is one OS process with no separate web server. During development you would
  normally run Vite instead, for hot reload — see `ui/README.md`.
  """
  use Plug.Router

  # `npm run build` writes the bundle to `priv/static`. Resolving it through
  # `Application.app_dir/2` (what an atom/tuple `:from` does, unlike a plain
  # relative path) means it works from any working directory and inside a
  # release.
  #
  # Only `assets` goes through this plug. Vite content-hashes those filenames, so
  # they can be cached forever; and confining the plug to that one prefix means a
  # stray file under `priv/static` can never shadow `/socket` or `/health`.
  # `index.html` is served by the route below instead, uncached, so that a
  # rebuild — which changes the asset hashes it points at — is picked up.
  plug Plug.Static,
    at: "/",
    from: {:manifold, "priv/static"},
    only: ["assets"],
    cache_control_for_etags: "public, max-age=31536000, immutable"

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

  get "/" do
    index = Application.app_dir(:manifold, "priv/static/index.html")

    if File.exists?(index) do
      conn
      |> put_resp_content_type("text/html")
      |> put_resp_header("cache-control", "no-cache")
      |> send_file(200, index)
    else
      # The app is perfectly usable without a built UI (that is what the Vite dev
      # server and `scripts/ws_smoke.exs` do), so this is a missing optional
      # asset, not a broken server. Say which command fixes it.
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(503, "UI not built. Run: cd ui && npm run build\n")
    end
  end

  # No SPA catch-all: the UI has no client-side router, so serving index.html for
  # unknown paths would only mask typos (`/helth`) behind a blank page.
  match _ do
    send_resp(conn, 404, "not found")
  end
end
