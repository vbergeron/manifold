defmodule Manifold.Smoke.EngineCostTest do
  use ExUnit.Case, async: false

  @moduletag :smoke
  @moduletag timeout: 120_000

  alias Manifold.Prolog.{Engine, MQI}

  @moduledoc """
  ASSUMPTION: an engine is cheap enough that one per conversation is affordable.

  Measured on SWI-Prolog 9.2.8, an 8-core Linux box:

    * boot to accepting connections — **~90 ms** (86/88/95/89/92 over five runs)
    * memory — ~9.7 MB RSS; PSS depends on how many engines are running, because that is what
      decides how much of the swipl image is shared. One engine alone measures ~7.4 MB PSS;
      across ten concurrent engines it falls to **~5.3 MB each**, which is the number that
      matters for capacity planning
    * 2 OS threads, 4 file descriptors
    * MQI round trip — **0.12 ms**

  Those numbers are the entire justification for the architecture: at 64 conversations it is
  ~340 MB and a sub-second boot storm. The ceilings asserted below are deliberately loose —
  they are meant to catch a change in kind (a swipl that now takes a second to start, or
  leaks 50 MB), not to measure jitter on a loaded machine.

  Run it when: upgrading SWI-Prolog, moving to different hardware, or revisiting the
  `:max_conversations` default.
  """

  test "boot to accepting connections stays well under a second" do
    # Three runs; report them all, assert on the median so one scheduling hiccup cannot fail
    # the build.
    timings =
      for _ <- 1..3 do
        started = System.monotonic_time(:millisecond)
        {:ok, engine} = Engine.start()
        {:ok, engine} = Engine.await_ready(engine)
        {:ok, conn} = Engine.connect(engine)
        elapsed = System.monotonic_time(:millisecond) - started

        MQI.close(conn)
        Engine.stop(engine)
        elapsed
      end

    median = timings |> Enum.sort() |> Enum.at(1)
    # Joined rather than inspected: a list of small integers renders as a charlist.
    IO.puts("\n  engine boot: #{Enum.join(timings, ", ")} ms (median #{median}, expected ~90)")

    assert median < 1_000, "engine boot has regressed by an order of magnitude: #{median} ms"
  end

  test "marginal memory stays in single-digit megabytes" do
    {:ok, engine} = Engine.start()
    {:ok, engine} = Engine.await_ready(engine)
    {:ok, conn} = Engine.connect(engine)
    {:ok, engine} = Engine.identify(engine, conn)

    pid = Engine.os_pid(engine)
    rss = proc_kb(pid, "Rss")
    pss = proc_kb(pid, "Pss")

    IO.puts("  engine memory: #{rss} kB RSS, #{pss} kB PSS (expected ~9700 / ~5300)")

    MQI.close(conn)
    Engine.stop(engine)

    # PSS is the number that matters when there are N of them: RSS double-counts the shared
    # libraries that dominate a swipl image.
    assert pss > 0, "could not read PSS from /proc — is this Linux?"
    assert pss < 30_000, "marginal engine memory has grown to #{pss} kB"
  end

  test "a round trip is well under a millisecond" do
    # Replay cost on rehydrate is one round trip per clause, so this sets how expensive it is
    # to bring a conversation back: at 0.12 ms, a 500-clause knowledge base is ~60 ms.
    {:ok, engine} = Engine.start()
    {:ok, engine} = Engine.await_ready(engine)
    {:ok, conn} = Engine.connect(engine)

    MQI.run(conn, "true")

    n = 200
    {micros, _} = :timer.tc(fn -> for i <- 1..n, do: MQI.run(conn, "assertz(bench(#{i}))") end)
    per_call = micros / n / 1000

    IO.puts("  round trip: #{Float.round(per_call, 3)} ms (expected ~0.12)")

    MQI.close(conn)
    Engine.stop(engine)

    assert per_call < 5.0, "MQI round trips have become expensive: #{per_call} ms"
  end

  defp proc_kb(pid, field) do
    case File.read("/proc/#{pid}/smaps_rollup") do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> Enum.find_value(0, fn line ->
          case String.split(line) do
            [^field <> ":", value, "kB"] -> String.to_integer(value)
            _ -> nil
          end
        end)

      {:error, _} ->
        0
    end
  end
end
