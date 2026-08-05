defmodule Manifold.Prolog.MQITest do
  use ExUnit.Case, async: true

  alias Manifold.Prolog.MQI
  alias Manifold.Test.MQIFake

  # Driven against a fake MQI server rather than a real swipl, which is what makes the
  # answer parser reachable: it is private and the only way in is over a socket. The value
  # is in the failure encodings — MQI expresses "no" three different ways, and conflating
  # any of them with a transport error is how a dead engine gets reported as a plain
  # negative.

  defp connect!(replies) do
    {:ok, fake} = MQIFake.start(replies: replies)
    {:ok, conn} = MQI.connect(MQIFake.target(fake))
    {fake, conn}
  end

  describe "authentication" do
    test "the first message is the password" do
      {fake, conn} = connect!([])
      assert [password] = MQIFake.received(fake)
      assert password == MQIFake.target(fake).password
      MQI.close(conn)
    end

    test "a rejected password is an error, not a connection" do
      {:ok, fake} = MQIFake.start(accept_auth: false)
      assert {:error, reason} = MQI.connect(MQIFake.target(fake))
      assert reason in [:auth_rejected] or match?({:auth_failed, _}, reason)
    end

    test "connecting to nothing fails rather than hanging" do
      # `Engine.connect/1` relies on this being `:econnrefused` specifically, so it can
      # retry MQI's bind-before-listen window and nothing else.
      assert {:error, :econnrefused} =
               MQI.connect(%{host: "127.0.0.1", port: 1, password: "irrelevant"})
    end
  end

  describe "answers" do
    test "a solution with no bindings is bare true" do
      # `[[]]` means "one solution, no variables" — not "one empty binding".
      {_fake, conn} = connect!([~s|{"functor":"true","args":[[[]]]}|])
      assert MQI.run(conn, "human(socrates)") == {:ok, true}
    end

    test "bindings come back decoded" do
      reply = ~s|{"functor":"true","args":[[[{"functor":"=","args":["X","socrates"]}]]]}|
      {_fake, conn} = connect!([reply])

      assert {:ok, {:bindings, [[binding]]}} = MQI.run(conn, "human(X)")
      assert binding == %{"functor" => "=", "args" => ["X", "socrates"]}
    end

    test "failure arrives in three different encodings, and all three mean false" do
      # A functor object, the JSON *string* "false", and the JSON boolean. Missing any one
      # of these would surface as `{:error, {:unexpected, _}}` and read as a broken engine.
      for reply <- [~s|{"functor":"false"}|, ~s|"false"|, "false"] do
        {_fake, conn} = connect!([reply])
        assert MQI.run(conn, "mortal(zeus)") == {:ok, false}, "encoding #{reply} misread"
      end
    end

    test "a Prolog exception is an error carrying its functor" do
      reply = ~s|{"functor":"exception","args":[{"functor":"time_limit_exceeded","args":[]}]}|
      {_fake, conn} = connect!([reply])
      assert MQI.run(conn, "loop(0)") == {:error, "time_limit_exceeded"}
    end

    test "a non-JSON reply is reported as such rather than crashing" do
      {_fake, conn} = connect!(["this is not json at all"])
      assert {:error, {:non_json_reply, _}} = MQI.run(conn, "anything")
    end

    test "an unrecognised shape is reported as unexpected" do
      {_fake, conn} = connect!([~s|{"functor":"surprise","args":[]}|])
      assert {:error, {:unexpected, _}} = MQI.run(conn, "anything")
    end
  end

  describe "the transport / Prolog distinction" do
    test "a dead socket is tagged :transport, never mistaken for an answer" do
      # This is the distinction the moduledoc insists on. Without the tag, a caller cannot
      # tell "Prolog says no" from "the engine is gone" — and the consequences are a clause
      # silently flagged and not persisted, a constraint quietly recorded as unchecked so
      # contradiction detection stops, and `{:error, :closed}` handed to a client as an
      # answer.
      {_fake, conn} = connect!([:close])

      assert {:error, {:transport, reason}} = MQI.run(conn, "anything")
      assert reason in [:closed, :econnreset]
    end

    test "a Prolog exception is NOT tagged :transport" do
      reply = ~s|{"functor":"exception","args":[{"functor":"existence_error","args":[]}]}|
      {_fake, conn} = connect!([reply])

      assert {:error, tag} = MQI.run(conn, "nosuch(x)")
      refute match?({:transport, _}, tag)
    end
  end

  describe "framing" do
    test "the goal reaches the server wrapped in run/2 with its timeout" do
      {fake, conn} = connect!([~s|{"functor":"true","args":[[[]]]}|])
      MQI.run(conn, "mortal(socrates)", 7)

      # The trailing period is framing rather than content, and the fake strips it along
      # with the newline — so what is recorded is the bare term.
      assert [_password, request] = MQIFake.received(fake)
      assert request == "run((mortal(socrates)), 7)"
    end

    test "a reply longer than 126 bytes round-trips, exercising the length prefix" do
      bindings =
        1..40
        |> Enum.map_join(",", fn i -> ~s|{"functor":"=","args":["X",#{i}]}| end)
        |> then(&~s|{"functor":"true","args":[[[#{&1}]]]}|)

      {_fake, conn} = connect!([bindings])
      assert {:ok, {:bindings, [solutions]}} = MQI.run(conn, "p(X)")
      assert length(solutions) == 40
    end
  end
end
