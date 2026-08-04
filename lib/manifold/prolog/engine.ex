defmodule Manifold.Prolog.Engine do
  @moduledoc """
  One SWI-Prolog MQI server, owned by one conversation.

  A plain module, not a process: `Manifold.Conversation` calls these functions and so
  **owns the `Port` itself**. That ownership is the isolation guarantee, and it is worth
  being precise about why, because the obvious alternatives are weaker.

  ## Why a process per conversation

  MQI gives each *connection* its own thread but **not** its own database — an ordinary
  `assertz/1` writes to the process-global store, so clauses asserted by one connection
  are visible to every other and outlive the connection that made them (measured, not
  assumed). Isolation can be asked for per predicate with `thread_local`, but that is
  isolation by discipline: one assert path that forgets the declaration leaks globally
  and permanently, because a predicate asserted before being declared can never be
  declared afterwards. A separate OS process needs no discipline.

  ## Why the Conversation owns the Port

  When the owning process exits — **for any reason, including `:kill`** — the emulator
  closes the port, which closes the guardian's stdin, and `Manifold.OsProcess`'s sh
  guardian kills the child. So "the engine cannot outlive its conversation" holds
  without `terminate/2` running, without `trap_exit`, and without a supervisor behaving
  correctly. Under a per-conversation supervisor the same invariant would live in a
  strategy atom, where changing `:one_for_all` to `:one_for_one` would silently produce
  a *doubled* knowledge base rather than a crash.

  A restarted conversation also gets a fresh MQI-assigned port and password, so a
  lingering predecessor is unreachable rather than merely unlikely.

  ## The launch, and three deliberate choices

    * **`port(_)` unbound.** MQI selects a free port and reports it, so there is no
      port allocation, no collision handling, and no fixed-port config that could not
      work for N engines anyway.
    * **No `password(_)` option.** MQI then generates one and reports it too. Passing
      it would put the secret in `argv`, world-readable through `/proc/<pid>/cmdline` —
      and N engines would mean N secrets in the process table.
    * **`query_timeout/1`** as a server-side backstop, so a runaway goal is bounded even
      if the Elixir side that set a per-query timeout has died.

  Rejected: a unix domain socket. It works (Erlang connects to `{:local, path}` and
  completes the MQI handshake), but swipl does not delete the socket file on SIGTERM, and
  the cleanup would have to live in `terminate/2` — the one callback that does not run on
  `:kill`. Litter would be guaranteed. Ephemeral loopback TCP has no filesystem resource
  at all.
  """
  require Logger

  alias Manifold.OsProcess
  alias Manifold.Prolog.MQI

  # Two OS pids, and confusing them is a bug worth naming.
  #
  # `guardian_pid` is what `OsProcess.open/3` hands back: the sh guardian, which is the
  # Port's direct child. `swipl_pid` is its child, obtained from Prolog itself once we can
  # talk to it. Signals must go to **swipl**:
  #
  #   * SIGKILLing the guardian bypasses its `trap`, so it never reaps swipl — the engine
  #     survives as an orphan reparented to init;
  #   * and worse, the Port does not report `:exit_status` while swipl still holds the
  #     inherited stdout pipe open, so the conversation never learns its engine is gone
  #     and carries on serving a corpse.
  #
  # Killing swipl instead lets the guardian's `wait` return normally, so it exits with the
  # child's status and the Port reports it. Measured, after getting it wrong.
  @enforce_keys [:port, :guardian_pid, :host]
  defstruct [:port, :guardian_pid, :host, :swipl_pid, :mqi_port, :password, buf: ""]

  @type t :: %__MODULE__{}

  # MQI binds to loopback itself, so this is not configurable: a setting here could
  # only ever be set to something that cannot work.
  @host "127.0.0.1"

  # 33x the measured ~90 ms boot — enough for a cold page cache on a loaded box.
  @boot_timeout_ms 3_000

  # Server-side ceiling on any single goal, independent of the per-query timeout the
  # caller passes to `MQI.run/3`.
  @query_timeout_s 30

  # MQI reports its address *after* bind() but *before* listen() (`mqi.pl` calls
  # `send_client_startup_data/5` from `mqi_start/1`, while `tcp_listen/2` is only
  # reached later inside the server thread). Connecting in that window gives
  # ECONNREFUSED on Linux. The gap is microseconds, but it is real.
  @connect_attempts 5
  @connect_backoff_ms 20

  @doc """
  Spawn a swipl MQI server. It is not usable until `await_ready/2` has read the address
  it reports on stdout.
  """
  @spec start() :: {:ok, t()} | {:error, term()}
  def start do
    goal =
      "use_module(library(mqi)), " <>
        "mqi_start([port(_), write_connection_values(true), " <>
        "run_server_on_thread(false), query_timeout(#{@query_timeout_s})])"

    # `run_server_on_thread(false)` keeps MQI's accept loop on the main thread so swipl
    # blocks and the process stays alive; the `mqi` CLI subcommand would start it on a
    # background thread and halt.
    case OsProcess.open("swipl", ["-q", "-g", goal, "-t", "halt"]) do
      {:ok, port, guardian_pid} ->
        {:ok, %__MODULE__{port: port, guardian_pid: guardian_pid, host: @host}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Learn the engine's real OS pid by asking it.

  `current_prolog_flag(pid, P)` is authoritative and costs one round trip, which beats
  guessing at the process tree with `pgrep -P`. Needed because the pid we get from
  spawning is the guardian's, not swipl's — see the struct.
  """
  @spec identify(t(), MQI.t()) :: {:ok, t()} | {:error, term()}
  def identify(%__MODULE__{} = engine, conn) do
    case MQI.run(conn, "current_prolog_flag(pid, P)") do
      {:ok, {:bindings, [[%{"args" => ["P", pid]} | _] | _]}} when is_integer(pid) ->
        {:ok, %{engine | swipl_pid: pid}}

      other ->
        {:error, {:pid_unavailable, other}}
    end
  end

  @doc """
  Block until the engine reports its port and password, or fail.

  Must be called from the process that owns the port, since it consumes the port's
  messages. Uses an *absolute* deadline: a per-chunk `after` would let chatty output
  re-arm the timer indefinitely.
  """
  @spec await_ready(t(), timeout()) :: {:ok, t()} | {:error, term()}
  def await_ready(%__MODULE__{} = engine, timeout \\ @boot_timeout_ms) do
    collect(engine, System.monotonic_time(:millisecond) + timeout)
  end

  @doc "Credentials for `Manifold.Prolog.MQI.connect/1`."
  @spec connection(t()) :: %{host: String.t(), port: pos_integer(), password: String.t()}
  def connection(%__MODULE__{host: host, mqi_port: port, password: password}) do
    %{host: host, port: port, password: password}
  end

  @doc "Open an MQI connection, absorbing the bind-before-listen window."
  @spec connect(t()) :: {:ok, MQI.t()} | {:error, term()}
  def connect(%__MODULE__{} = engine), do: connect(engine, @connect_attempts)

  @doc """
  Absorb a chunk of the engine's output in steady state, logging whole lines.

  Partial lines are held in the struct rather than logged, because swipl's stderr is
  merged into this stream and arrives split at arbitrary boundaries.
  """
  @spec log_data(t(), binary()) :: t()
  def log_data(%__MODULE__{} = engine, chunk) do
    {lines, rest} = split_lines(engine.buf <> chunk)
    Enum.each(lines, &log_line/1)
    %{engine | buf: rest}
  end

  @doc """
  The OS pid to signal to destroy this engine, or `nil` before `identify/2` has run.
  """
  @spec os_pid(t()) :: non_neg_integer() | nil
  def os_pid(%__MODULE__{swipl_pid: swipl_pid}), do: swipl_pid

  @doc """
  Stop the engine, terminating swipl and letting the guardian follow it out.

  Closing the Port would achieve this anyway — that is the guarantee — so this is the
  tidy path, not the safety net.
  """
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{swipl_pid: nil, guardian_pid: guardian_pid}) do
    # Boot failed before we could ask its pid; SIGTERM the guardian so its trap reaps
    # whatever it started.
    OsProcess.kill(guardian_pid)
  end

  def stop(%__MODULE__{swipl_pid: swipl_pid}), do: OsProcess.kill(swipl_pid)

  # --- readiness --------------------------------------------------------------

  defp collect(%__MODULE__{mqi_port: port, password: password} = engine, _deadline)
       when is_integer(port) and is_binary(password) do
    {:ok, engine}
  end

  defp collect(%__MODULE__{port: port} = engine, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :boot_timeout}
    else
      receive do
        {^port, {:data, chunk}} ->
          engine |> absorb(chunk) |> collect(deadline)

        # swipl gave up before reporting an address — a bad goal, a missing library.
        # Distinguishable from a timeout, and worth distinguishing in the log.
        {^port, {:exit_status, code}} ->
          {:error, {:exited_during_boot, code}}
      after
        remaining -> {:error, :boot_timeout}
      end
    end
  end

  defp absorb(engine, chunk) do
    {lines, rest} = split_lines(engine.buf <> chunk)
    Enum.reduce(lines, %{engine | buf: rest}, &take_line(&2, &1))
  end

  # The port is the first line that is *only* digits. Anything before it is a warning —
  # stderr is merged into this stream — so it is logged and skipped rather than treated
  # as a boot failure.
  defp take_line(%__MODULE__{mqi_port: nil} = engine, line) do
    case Integer.parse(line) do
      {port, ""} ->
        %{engine | mqi_port: port}

      _ ->
        log_line(line)
        engine
    end
  end

  # Then the password, on the next non-empty line. Note it is *also* all digits, so the
  # two are told apart only by order — which is why the port must be taken first.
  defp take_line(%__MODULE__{password: nil} = engine, line) when line != "" do
    %{engine | password: line}
  end

  defp take_line(engine, line) do
    log_line(line)
    engine
  end

  defp connect(engine, attempts) do
    case MQI.connect(connection(engine)) do
      {:ok, conn} ->
        {:ok, conn}

      {:error, :econnrefused} when attempts > 1 ->
        Process.sleep(@connect_backoff_ms)
        connect(engine, attempts - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- lines ------------------------------------------------------------------

  # Everything up to the last newline is complete; the remainder is held for the next
  # chunk.
  defp split_lines(buf) do
    case String.split(buf, "\n") do
      [only] -> {[], only}
      parts -> {parts |> Enum.drop(-1) |> Enum.map(&String.trim/1), List.last(parts)}
    end
  end

  defp log_line(""), do: :ok
  defp log_line(line), do: Logger.debug(["[engine] ", line])
end
