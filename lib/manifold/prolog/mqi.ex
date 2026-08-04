defmodule Manifold.Prolog.MQI do
  @moduledoc """
  Minimal client for SWI-Prolog's Machine Query Interface (MQI).

  Wire format (both directions): a message is a UTF-8 Prolog-term string ending
  in `.\\n`, prefixed by its byte length as ASCII digits, a `.`, and a newline:

      <byte-length>.\\n<message-bytes>

  One TCP connection is one Prolog **thread** — but *not* one database. This is the
  single most important thing to know about MQI here: an ordinary `assertz/1` over
  any connection writes to the process-global store, so clauses asserted by one
  connection are visible to every other, and they outlive the connection that made
  them. Measured, not assumed.

  Isolation therefore has to be asked for. `Manifold.Conversation` declares every
  predicate `thread_local` before asserting into it, which confines its clauses to
  the asserting connection's thread and discards them when that thread ends. That
  is what makes a connection behave as its own knowledge base — the Prolog half of
  Manifold's "doubling" — and `Manifold.Conversation.assertion/1` is the only place
  that may assert, because a predicate asserted before being declared can never be
  declared afterwards.

  This implements just enough of the protocol for Manifold: authenticate, `run/3`
  a goal with a timeout, and `close/1`. MQI serializes answers as JSON, so
  variable bindings come back already decoded into Elixir maps/lists.
  """
  require Logger

  @enforce_keys [:sock]
  defstruct [:sock]

  @type t :: %__MODULE__{sock: port()}

  @recv_timeout 30_000

  @doc "Open and authenticate an MQI connection using `Manifold.Prolog.Server`'s credentials."
  @spec connect(keyword()) :: {:ok, t()} | {:error, term()}
  def connect(opts \\ []) do
    %{host: host, port: port, password: password} = Manifold.Prolog.Server.connection()
    host = Keyword.get(opts, :host, host)
    port = Keyword.get(opts, :port, port)

    with {:ok, sock} <-
           :gen_tcp.connect(
             String.to_charlist(host),
             port,
             [:binary, active: false, packet: :raw],
             5_000
           ),
         conn = %__MODULE__{sock: sock},
         :ok <- send_message(conn, password),
         {:ok, reply} <- recv_message(conn) do
      # A successful auth replies `true(...)` (carrying thread/version info).
      case parse(reply) do
        {:error, reason} ->
          :gen_tcp.close(sock)
          {:error, {:auth_failed, reason}}

        false ->
          :gen_tcp.close(sock)
          {:error, :auth_rejected}

        _ok ->
          {:ok, conn}
      end
    end
  end

  @doc """
  Run `goal` (a Prolog goal string, no trailing `.`) with a timeout in seconds
  (`-1` = no limit). Returns:

    * `{:ok, true}`             — succeeded, no bindings
    * `{:ok, {:bindings, sols}}` — succeeded; `sols` is the decoded JSON list of
                                   solutions, each a list of `=`-binding maps
    * `{:ok, false}`            — failed
    * `{:error, reason}`        — a Prolog exception (e.g. `"time_limit_exceeded"`)
  """
  @spec run(t(), String.t(), integer()) :: {:ok, term()} | {:error, term()}
  def run(%__MODULE__{} = conn, goal, timeout_s \\ 10) do
    with :ok <- send_message(conn, "run((#{goal}), #{timeout_s})"),
         {:ok, reply} <- recv_message(conn) do
      {:ok, parse(reply)}
    end
    |> case do
      {:ok, {:error, e}} -> {:error, e}
      {:ok, parsed} -> {:ok, parsed}
      {:error, _} = err -> err
    end
  end

  @doc "Politely close the MQI connection and the socket."
  @spec close(t()) :: :ok
  def close(%__MODULE__{sock: sock} = conn) do
    _ = send_message(conn, "close")
    :gen_tcp.close(sock)
  end

  # --- framing ---------------------------------------------------------------

  defp send_message(%__MODULE__{sock: sock}, text) do
    message = text <> ".\n"
    frame = "#{byte_size(message)}.\n" <> message
    :gen_tcp.send(sock, frame)
  end

  defp recv_message(%__MODULE__{sock: sock}) do
    with {:ok, len} <- recv_length(sock, ""),
         {:ok, body} <- :gen_tcp.recv(sock, len, @recv_timeout) do
      {:ok, String.trim_trailing(body)}
    end
  end

  # Read ASCII digits up to the '.', then consume the trailing '\n'.
  defp recv_length(sock, acc) do
    case :gen_tcp.recv(sock, 1, @recv_timeout) do
      {:ok, "."} ->
        case :gen_tcp.recv(sock, 1, @recv_timeout) do
          {:ok, "\n"} -> {:ok, String.to_integer(acc)}
          {:ok, other} -> {:error, {:bad_frame, other}}
          err -> err
        end

      {:ok, digit} ->
        recv_length(sock, acc <> digit)

      err ->
        err
    end
  end

  # --- response parsing ------------------------------------------------------

  # MQI serializes answers as JSON: the Prolog term `true(Solutions)`,
  # `false`, or `exception(Error)` becomes {"functor": ..., "args": [...]}.
  # `Solutions` is a list of solutions; each solution is a list of bindings.
  defp parse(json) do
    case Jason.decode(json) do
      {:ok, %{"functor" => "true", "args" => [solutions]}} ->
        # `[[]]` == a single solution with no variable bindings.
        if solutions == [[]], do: true, else: {:bindings, solutions}

      {:ok, %{"functor" => "false"}} ->
        false

      # Goal failure comes back as the Prolog atom `false`, which MQI encodes as
      # the JSON string "false" (not a boolean, not a functor object).
      {:ok, "false"} ->
        false

      {:ok, false} ->
        false

      {:ok, %{"functor" => "exception", "args" => args}} ->
        {:error, exception_reason(args)}

      {:ok, other} ->
        {:error, {:unexpected, other}}

      {:error, %Jason.DecodeError{}} ->
        {:error, {:non_json_reply, json}}
    end
  end

  defp exception_reason([%{"functor" => f} | _]), do: f
  defp exception_reason([reason | _]), do: reason
  defp exception_reason(other), do: other
end
