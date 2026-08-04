export const WS_URL: string =
  import.meta.env.VITE_WS_URL ?? "ws://127.0.0.1:4000/socket";

/**
 * Dev-only fake event feed, so the UI can be driven without the Elixir server.
 * Enabled by `VITE_MOCK=1` or by appending `?mock=1` to the URL. Never active
 * in a production build — a real connection is the only path there.
 */
export const USE_MOCK: boolean =
  import.meta.env.DEV &&
  (import.meta.env.VITE_MOCK === "1" ||
    new URLSearchParams(window.location.search).has("mock"));
