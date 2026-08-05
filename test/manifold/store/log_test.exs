defmodule Manifold.Store.LogTest do
  use ExUnit.Case, async: true

  # Several tests deliberately feed the adapter corrupt or future-versioned logs, and it is
  # supposed to complain loudly about exactly that. Capture it so a green run stays readable.
  @moduletag :capture_log

  alias Manifold.Store
  alias Manifold.Store.Log

  setup do
    # Each test gets its own directory, and never the repo's `data/`.
    dir = Path.join(System.tmp_dir!(), "manifold-log-test-#{System.unique_integer([:positive])}")
    opts = [dir: dir, sync: true]
    :ok = Log.setup(opts)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir, opts: opts}
  end

  defp clause(id, text, kind), do: %{id: id, text: text, kind: kind, turn: "t1"}

  describe "round trip" do
    test "replays events in order", %{opts: opts} do
      {:ok, h} = Log.open("conv_a", opts)
      :ok = Log.append(h, [{:clauses, [clause("c1", "human(socrates).", "fact")]}])
      :ok = Log.append(h, [{:message, %{id: "m1", kind: "user", turn: "t1", text: "hi"}}])

      assert {:ok, events} = Log.replay(h)

      assert [
               {:clauses, [%{id: "c1", text: "human(socrates).", kind: "fact", turn: "t1"}]},
               {:message, %{id: "m1", kind: "user", text: "hi"}}
             ] = events

      Log.close(h)
    end

    test "preserves atom keys and the answer union exactly", %{opts: opts} do
      # This is why the format is ETF rather than JSON: `answer` is
      # `true | false | %{bindings: […]}` and every map key is an atom. JSON would coerce
      # both and leave the replay code guessing types back.
      {:ok, h} = Log.open("conv_types", opts)
      message = %{id: "m1", kind: "query", turn: "t1", goal: "mortal(socrates)", answer: true}
      :ok = Log.append(h, [{:message, message}])

      assert {:ok, [{:message, replayed}]} = Log.replay(h)
      assert replayed == message
      assert replayed.answer === true, "must not come back as the string \"true\""
      Log.close(h)
    end

    test "an empty log replays as empty, and a missing file is not an error", %{opts: opts} do
      {:ok, h} = Log.open("conv_empty", opts)
      assert Log.replay(h) == {:ok, []}
      Log.close(h)
    end
  end

  describe "an interrupted write" do
    setup %{opts: opts} do
      # Three batches, the last carrying two events, so a torn tail is distinguishable from
      # a lost single event.
      {:ok, h} = Log.open("conv_torn", opts)
      :ok = Log.append(h, [{:clauses, [clause("c1", "p(1).", "fact")]}])
      :ok = Log.append(h, [{:message, %{id: "m1", kind: "user", turn: "t1", text: "one"}}])

      :ok =
        Log.append(h, [
          {:clauses, [clause("c2", "p(2).", "fact")]},
          {:message, %{id: "m2", kind: "user", turn: "t2", text: "two"}}
        ])

      Log.close(h)
      {:ok, path: Path.join(opts[:dir], "conv_torn.log")}
    end

    for chop <- [1, 5, 20] do
      test "chopping #{chop} bytes loses whole batches only, never half a turn", ctx do
        bytes = File.read!(ctx.path)
        File.write!(ctx.path, binary_part(bytes, 0, byte_size(bytes) - unquote(chop)))

        {:ok, h} = Log.open("conv_torn", ctx.opts)
        assert {:ok, events} = Log.replay(h)
        Log.close(h)

        # The last batch held two events, so recovering 3 would mean a half-written turn was
        # replayed. That is exactly what framing a batch as one frame prevents: `:file.write`
        # of an iolist is a single write(), but POSIX does not promise it is all-or-nothing.
        assert length(events) == 2
        refute length(events) == 3
      end
    end

    test "a complete but undecodable frame replays empty rather than raising", %{
      dir: dir,
      opts: opts
    } do
      # A valid 32-bit length with a garbage payload: corruption, not an interrupted write.
      File.write!(Path.join(dir, "conv_bad.log"), <<9::32, "not-a-term">>)
      {:ok, h} = Log.open("conv_bad", opts)
      assert Log.replay(h) == {:ok, []}
      Log.close(h)
    end

    test "a log with no recognisable header is refused, not guessed at", %{dir: dir, opts: opts} do
      term = :erlang.term_to_binary({:message, %{id: "m1"}})
      File.write!(Path.join(dir, "conv_hdr.log"), <<byte_size(term)::32>> <> term)

      {:ok, h} = Log.open("conv_hdr", opts)
      assert Log.replay(h) == {:ok, []}
      Log.close(h)
    end

    test "a log written by a future version is refused", %{dir: dir, opts: opts} do
      header = :erlang.term_to_binary({:manifold_log, 99})
      File.write!(Path.join(dir, "conv_v99.log"), <<byte_size(header)::32>> <> header)

      {:ok, h} = Log.open("conv_v99", opts)
      assert Log.replay(h) == {:ok, []}
      Log.close(h)
    end
  end

  describe "conversation ids are untrusted input" do
    # They arrive from the client in `open {conversation_id}` and become filenames.
    for bad <- ["../../etc/passwd", "..", "a/b", "conv with space", "", "tab\there"] do
      test "refuses #{inspect(bad)}", %{opts: opts} do
        assert {:error, {:unsafe_conversation_id, _}} = Log.open(unquote(bad), opts)
      end
    end

    test "refuses an over-long id", %{opts: opts} do
      assert {:error, {:unsafe_conversation_id, _}} = Log.open(String.duplicate("x", 200), opts)
    end

    test "refuses rather than sanitises", %{opts: opts} do
      # Silently rewriting an id would open one conversation under another's name.
      refute File.exists?(Path.join(opts[:dir], "passwd.log"))
      assert {:error, _} = Log.open("../../etc/passwd", opts)
      assert File.ls!(opts[:dir]) == []
    end

    test "accepts a real minted id", %{opts: opts} do
      assert {:ok, h} = Log.open(Manifold.Conversation.new_id(), opts)
      Log.close(h)
    end

    test "delete validates the id too", %{opts: opts} do
      assert {:error, {:unsafe_conversation_id, _}} = Log.delete("../x", opts)
    end
  end

  describe "list and delete" do
    test "lists what has been written and forgets what is deleted", %{opts: opts} do
      {:ok, h} = Log.open("conv_listed", opts)
      Log.close(h)

      assert {:ok, ids} = Log.list(opts)
      assert "conv_listed" in ids

      assert :ok = Log.delete("conv_listed", opts)
      assert {:ok, remaining} = Log.list(opts)
      refute "conv_listed" in remaining
    end

    test "delete is idempotent", %{opts: opts} do
      assert Log.delete("never_existed", opts) == :ok
    end

    test "listing a directory that does not exist is empty, not an error" do
      assert Log.list(dir: "/nonexistent/manifold-test") == {:ok, []}
    end
  end

  describe "the null adapter and the facade" do
    test "a conversation with no id is not persisted" do
      # There is nothing a durable copy could be used for: it cannot be re-attached to.
      store = Store.open(nil)
      assert store.mod == Manifold.Store.None
      assert Store.append(store, [{:message, %{id: "m1"}}]) == :ok
      assert Store.replay(store) == []
    end

    test "an empty batch never reaches the adapter" do
      assert Store.append(Store.open(nil), []) == :ok
    end
  end
end
