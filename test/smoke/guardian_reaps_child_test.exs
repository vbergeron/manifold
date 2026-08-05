defmodule Manifold.Smoke.GuardianReapsChildTest do
  use ExUnit.Case, async: false

  @moduletag :smoke
  @moduletag timeout: 60_000

  alias Manifold.OsProcess

  @moduledoc """
  ASSUMPTION: the sh guardian kills its child when the **Port-owning process** dies — not
  only when the whole BEAM does.

  This is the load-bearing fact behind the whole ownership design. Because it holds,
  "an engine cannot outlive its conversation" needs no supervisor strategy, no `trap_exit`
  and no `terminate/2`: a conversation exiting for *any* reason, including `:kill`, closes
  its port, which closes the guardian's stdin, and the guardian reaps swipl.

  If it ever stops holding, every killed conversation leaks an OS process and the design
  needs an explicit reaper. Measured on Linux 6.8 with `/bin/sh` = dash.

  Run it when: changing `Manifold.OsProcess`, moving to a different platform or shell, or
  investigating leaked swipl processes.
  """

  defp swipl_count do
    {out, _} = System.cmd("bash", ["-c", "pgrep -x swipl | wc -l"])
    out |> String.trim() |> String.to_integer()
  end

  test "the child dies when only its owning process dies" do
    baseline = swipl_count()

    parent = self()

    owner =
      spawn(fn ->
        {:ok, _port, guardian_pid} =
          OsProcess.open("swipl", ["-q", "-g", "sleep(600)", "-t", "halt"])

        send(parent, {:started, guardian_pid})
        Process.sleep(:infinity)
      end)

    receive do
      {:started, _guardian} -> :ok
    after
      10_000 -> flunk("swipl never started")
    end

    assert eventually(fn -> swipl_count() > baseline end), "the child should be running"

    # Kill *only* the Elixir process that owns the port — the BEAM stays up. This is exactly
    # what happens when a conversation is `:kill`ed, which is routine here: it is how
    # `cancel_turn` and the runaway-query kill switch work.
    Process.exit(owner, :kill)

    assert eventually(fn -> swipl_count() == baseline end, 10_000),
           """
           The guardian no longer reaps its child when the Port owner dies.

           Every killed conversation now leaks a swipl process. `Manifold.Prolog.Engine`'s
           ownership argument depends on this, so it needs an explicit reaper before that
           argument can be trusted again.
           """
  end

  test "a child that ignores SIGTERM is escalated to SIGKILL" do
    # `OsProcess.kill/2` promises TERM, then KILL, then confirmation. A goal spinning inside
    # a foreign predicate may never reach a signal handler, which is why the escalation has
    # to exist rather than being belt-and-braces.
    {:ok, _port, guardian_pid} =
      OsProcess.open("sh", ["-c", "trap '' TERM; while :; do sleep 1; done"])

    assert eventually(fn -> alive?(guardian_pid) end)
    assert OsProcess.kill(guardian_pid) == :ok
    refute alive?(guardian_pid), "kill/2 returned before the process was actually gone"
  end

  defp alive?(os_pid) do
    match?({_, 0}, System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true))
  end

  defp eventually(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> Process.sleep(50) && do_eventually(fun, deadline)
    end
  end
end
