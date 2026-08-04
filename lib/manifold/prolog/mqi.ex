defmodule Manifold.Prolog.MQI do
  @moduledoc """
  Minimal client for SWI-Prolog's Machine Query Interface (MQI).

  Wire format (both directions): a message is a UTF-8 Prolog-term string ending
  in `.\\n`, prefixed by its byte length as ASCII digits, a `.`, and a newline:

      <byte-length>.\\n<message-bytes>

  One TCP connection is one Prolog **thread** — but *not* one database. This is the
  single most important thing to know about MQI: an ordinary `assertz/1` over any
  connection writes to the process-global store, so clauses asserted by one connection
  are visible to every other, and they outlive the connection that made them. Measured,
  not assumed.

  That is a fact about MQI, not a problem this module solves. Manifold's answer is one
  swipl *process* per conversation — see `Manifold.Prolog.Engine`, which is also where
  a connection's credentials come from.

  This implements just enough of the protocol for Manifold: authenticate, `run/3`
  a goal with a timeout, and `close/1`. MQI serializes answers as JSON, so
  variable bindings come back already decoded into Elixir maps/lists.
  """
  require Logger

  @enforce_keys [:sock]
  defstruct [:sock]

  @type t :: %__MODULE__{sock: port()}

  @recv_timeout 30_000

  @typedoc "Where an engine is listening, as reported by `Manifold.Prolog.Engine.connection/1`."
  @type target :: %{host: String.t(), port: pos_integer(), password: String.t()}

  @doc """
  Open and authenticate a connection to the engine described by `target`.

  Deliberately takes its target rather than reaching for a global server: there is one
  engine per conversation, each with its own port and password.
  """
  @spec connect(target()) :: {:ok, t()} | {:error, term()}
  def connect(%{host: host, port: port, password: password}) do
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

    * `{:ok, true}`              — succeeded, no bindings
    * `{:ok, {:bindings, sols}}` — succeeded; `sols` is the decoded JSON list of
                                   solutions, each a list of `=`-binding maps
    * `{:ok, false}`             — failed
    * `{:error, reason}`         — a Prolog exception (e.g. `"time_limit_exceeded"`)
    * `{:error, {:transport, r}}` — **the engine is gone**, not an answer

  The last case is deliberately distinguishable. Conflating "Prolog says no" with "the
  socket is dead" is how a dead engine gets reported as a plain negative: a clause
  flagged `"closed"` and not persisted, a constraint quietly recorded as unchecked so
  contradiction detection stops, or `{:error, :closed}` handed to a client as though it
  were an answer. Callers must treat `{:transport, _}` as fatal to the conversation and
  let it rehydrate — the store is the truth.
  """
  @spec run(t(), String.t(), integer()) :: {:ok, term()} | {:error, term()}
  def run(%__MODULE__{} = conn, goal, timeout_s \\ 10) do
    with :ok <- transport(send_message(conn, "run((#{goal}), #{timeout_s})")),
         {:ok, reply} <- transport(recv_message(conn)) do
      case parse(reply) do
        {:error, prolog_error} -> {:error, prolog_error}
        parsed -> {:ok, parsed}
      end
    end
  end

  defp transport({:error, reason}), do: {:error, {:transport, reason}}
  defp transport(other), do: other

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
