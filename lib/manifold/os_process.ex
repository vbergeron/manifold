defmodule Manifold.OsProcess do
  @moduledoc """
  Helpers for owning an external OS process through an Erlang `Port`.

  Two things matter here:

    * We resolve the executable on `PATH` (mise puts `llama-server` there;
      `swipl` is a system binary), so the supervised servers stay declarative.
    * A `Port` does **not** guarantee the child dies with the BEAM. We capture
      the child's OS pid so the owning GenServer can `kill/1` it in
      `terminate/2`, avoiding orphaned sidecars on shutdown/restart.
  """
  require Logger

  # A `Port` does not kill its OS child when the BEAM dies abnormally (a raised
  # script, a hard halt) — `terminate/2` only runs on *graceful* shutdown. So we
  # never spawn the target directly; we spawn it under this POSIX-sh guardian,
  # which kills the child when:
  #   * our stdin (the BEAM port's pipe) hits EOF  — the BEAM went away, or
  #   * the guardian itself receives SIGTERM       — graceful terminate/2.
  # It exits with the child's own status so the Port still reports crashes.
  @guardian ~S"""
  trap 'kill -TERM "$pid" 2>/dev/null' TERM INT
  # Save the port's stdin to fd 3: backgrounding a job in non-interactive sh
  # redirects its stdin to /dev/null, so the watcher must read the real fd.
  exec 3<&0
  "$@" &
  pid=$!
  ( cat <&3 >/dev/null 2>&1; kill -TERM "$pid" 2>/dev/null ) &
  watcher=$!
  wait "$pid"
  status=$?
  kill -TERM "$watcher" 2>/dev/null
  exit $status
  """

  @doc """
  Spawn `executable args...` as a Port-owned OS process.

  Returns `{:ok, port, os_pid}` or `{:error, {:executable_not_found, name}}`.
  The port is opened with `:exit_status` so the owner is notified when the
  child dies, and `:stderr_to_stdout` so logs are captured in one stream.
  """
  @spec open(String.t(), [String.t()], keyword()) ::
          {:ok, port(), non_neg_integer()} | {:error, term()}
  def open(executable, args, opts \\ []) do
    case System.find_executable(executable) do
      nil ->
        {:error, {:executable_not_found, executable}}

      path ->
        sh = System.find_executable("sh") || "/bin/sh"
        # sh -c SCRIPT $0 $1..  → $0 is a label, $1.. are the program + its args,
        # which `"$@"` inside the guardian expands to run.
        guardian_args = ["-c", @guardian, "manifold-guardian", path | args]

        port_opts =
          [:binary, :exit_status, :stderr_to_stdout, {:args, guardian_args}] ++
            maybe(:cd, opts[:cd]) ++
            maybe(:env, encode_env(opts[:env]))

        port = Port.open({:spawn_executable, sh}, port_opts)
        {:os_pid, os_pid} = Port.info(port, :os_pid)
        {:ok, port, os_pid}
    end
  end

  # How long a child gets to honour SIGTERM before it is killed outright.
  @escalate_after_ms 2_000

  @doc """
  Signal an OS pid, escalating to `SIGKILL` if it does not go away. Safe with `nil`.

  `signal` may be `"TERM"` (default, escalating) or `"KILL"` (immediate, no grace). Death
  is *confirmed* rather than assumed: best-effort-and-shrug was fine for two long-lived
  sidecars, but one engine per conversation means this runs constantly, and a child that
  ignores SIGTERM — a goal spinning inside a foreign predicate never reaches its signal
  handler — would otherwise leak silently.
  """
  @spec kill(non_neg_integer() | nil, String.t()) :: :ok
  def kill(os_pid, signal \\ "TERM")

  def kill(nil, _signal), do: :ok

  def kill(os_pid, "KILL") when is_integer(os_pid) do
    signal(os_pid, "KILL")
    :ok
  end

  def kill(os_pid, signal) when is_integer(os_pid) do
    signal(os_pid, signal)

    unless await_death(os_pid, System.monotonic_time(:millisecond) + @escalate_after_ms) do
      Logger.warning("[os] pid #{os_pid} ignored SIG#{signal} for #{@escalate_after_ms}ms — escalating to SIGKILL")
      signal(os_pid, "KILL")
    end

    :ok
  end

  defp signal(os_pid, sig) do
    System.cmd("kill", ["-#{sig}", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp await_death(os_pid, deadline) do
    if alive?(os_pid) do
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(50)
        await_death(os_pid, deadline)
      end
    else
      true
    end
  end

  # `kill -0` signals nothing and only reports whether the pid is signallable.
  defp alive?(os_pid) do
    match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true))
  rescue
    _ -> false
  end

  defp maybe(_key, nil), do: []
  defp maybe(key, value), do: [{key, value}]

  # Port env wants charlists.
  defp encode_env(nil), do: nil

  defp encode_env(env) when is_list(env) or is_map(env) do
    Enum.map(env, fn {k, v} ->
      {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))}
    end)
  end
end
