/**
 * Where to reach the server's socket.
 *
 * In a production build the page is served by the Elixir app itself, so the
 * socket is same-origin: derive it from `window.location` rather than hardcoding
 * a host. That is what makes the app work when reached over the network or behind
 * TLS (`https:` requires `wss:` — a fixed `ws://` URL would be blocked as mixed
 * content).
 *
 * In dev the page comes from Vite on `:5173` while the server is on `:4000`, so
 * the origin is the wrong answer and the default points at the server directly.
 * `VITE_WS_URL` overrides either case.
 */
function defaultWsUrl(): string {
  if (import.meta.env.DEV) return "ws://127.0.0.1:4000/socket";

  const scheme = window.location.protocol === "https:" ? "wss:" : "ws:";
  return `${scheme}//${window.location.host}/socket`;
}

export const WS_URL: string = import.meta.env.VITE_WS_URL ?? defaultWsUrl();

/**
 * Dev-only fake event feed, so the UI can be driven without the Elixir server.
 * Enabled by `VITE_MOCK=1` or by appending `?mock=1` to the URL. Never active
 * in a production build — a real connection is the only path there.
 */
export const USE_MOCK: boolean =
  import.meta.env.DEV &&
  (import.meta.env.VITE_MOCK === "1" ||
    new URLSearchParams(window.location.search).has("mock"));
