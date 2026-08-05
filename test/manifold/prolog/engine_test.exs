defmodule Manifold.Prolog.EngineTest do
  use ExUnit.Case, async: true

  alias Manifold.Prolog.Engine

  # No swipl needed. `await_ready/2` selectively receives `{port, {:data, chunk}}` where
  # `port` is whatever term the struct carries — it is never used as a real port — so the
  # whole boot handshake can be driven with hand-sent messages. That makes the fiddliest
  # part of engine startup a pure test.

  defp fake_engine(tag \\ :fake_port) do
    %Engine{port: tag, guardian_pid: 111, host: "127.0.0.1"}
  end

  describe "reading the address MQI reports on stdout" do
    test "takes the port then the password" do
      engine = fake_engine()
      send(self(), {:fake_port, {:data, "44781\n337307444853818355875167469552591855154\n"}})

      assert {:ok, ready} = Engine.await_ready(engine, 500)
      assert ready.mqi_port == 44781
      assert ready.password == "337307444853818355875167469552591855154"
    end

    test "order is the only thing separating them, since both are all digits" do
      # MQI's generated password is a 39-digit number. If the parser looked for "the digit
      # line" rather than "the *first* digit line", it could take the password as the port.
      engine = fake_engine()
      send(self(), {:fake_port, {:data, "5001\n999999999999\n"}})

      assert {:ok, ready} = Engine.await_ready(engine, 500)
      assert ready.mqi_port == 5001
      assert ready.password == "999999999999"
    end

    test "reassembles across arbitrary chunk boundaries" do
      # stdout arrives in whatever pieces the OS chooses; a line can be split anywhere.
      engine = fake_engine()
      send(self(), {:fake_port, {:data, "447"}})
      send(self(), {:fake_port, {:data, "81\nsecr"}})
      send(self(), {:fake_port, {:data, "et\n"}})

      assert {:ok, ready} = Engine.await_ready(engine, 500)
      assert ready.mqi_port == 44781
      assert ready.password == "secret"
    end

    test "skips warnings that arrive before the address" do
      # stderr is merged into this stream, so a locale or library warning can land first. A
      # strict "line 1 is the port" rule would turn a cosmetic message into a boot failure.
      engine = fake_engine()
      send(self(), {:fake_port, {:data, "Warning: something cosmetic\n4242\npw\n"}})

      assert {:ok, ready} = Engine.await_ready(engine, 500)
      assert ready.mqi_port == 4242
      assert ready.password == "pw"
    end

    test "leaves unrelated messages in the mailbox" do
      # It runs inside a live process, so a selective receive is required rather than a
      # blanket one.
      engine = fake_engine()
      send(self(), {:something_else, :entirely})
      send(self(), {:fake_port, {:data, "1234\npw\n"}})

      assert {:ok, _} = Engine.await_ready(engine, 500)
      assert_received {:something_else, :entirely}
    end
  end

  describe "boot failures are distinguishable" do
    test "swipl exiting before reporting an address is not a timeout" do
      engine = fake_engine()
      send(self(), {:fake_port, {:exit_status, 2}})

      assert Engine.await_ready(engine, 500) == {:error, {:exited_during_boot, 2}}
    end

    test "silence times out" do
      assert Engine.await_ready(fake_engine(), 50) == {:error, :boot_timeout}
    end

    test "chatty output cannot re-arm the deadline forever" do
      # The deadline is absolute. A per-chunk `after` would let noise postpone the timeout
      # indefinitely, so this asserts the timeout still fires while data keeps arriving.
      engine = fake_engine()
      for _ <- 1..50, do: send(self(), {:fake_port, {:data, "noise, no address here\n"}})

      assert Engine.await_ready(engine, 100) == {:error, :boot_timeout}
    end
  end

  describe "connection/1" do
    test "reports credentials in the shape MQI.connect/1 wants" do
      engine = %{fake_engine() | mqi_port: 9999, password: "pw"}
      assert Engine.connection(engine) == %{host: "127.0.0.1", port: 9999, password: "pw"}
    end
  end

  describe "os_pid/1" do
    test "is swipl's pid, not the guardian's" do
      # Signals must reach swipl: killing the guardian bypasses its trap so it never reaps
      # its child, and the Port reports no exit status while swipl still holds the pipe.
      engine = %{fake_engine() | swipl_pid: 4242}
      assert Engine.os_pid(engine) == 4242
      refute Engine.os_pid(engine) == engine.guardian_pid
    end

    test "is nil before the engine has been asked its pid" do
      assert Engine.os_pid(fake_engine()) == nil
    end
  end

  describe "log_data/2" do
    test "holds a partial line back rather than logging it" do
      engine = %{fake_engine() | buf: ""}
      assert Engine.log_data(engine, "complete line\npart").buf == "part"
    end

    test "empties the buffer when the chunk ends on a newline" do
      assert Engine.log_data(%{fake_engine() | buf: "half "}, "done\n").buf == ""
    end
  end
end
