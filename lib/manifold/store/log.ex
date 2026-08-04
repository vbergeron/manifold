defmodule Manifold.Store.Log do
  @moduledoc """
  Append-only ETF log, one file per conversation.

  ## Frame format

      <<size::32>> <> :erlang.term_to_binary(term)

  The first frame of a file is the header `{:manifold_log, 1}`; every frame after it
  is **one whole batch** — a list of `Manifold.Store.event/0`. ETF rather than JSON
  because it round-trips the maps exactly: JSON would coerce the `answer` union
  (`true | false | %{bindings: […]}`) and every atom map key, leaving the replay
  code to guess types back.

  A batch is one frame, not one frame per event, and that is what makes the
  behaviour's atomicity promise true here. `:file.write/2` of an iolist is a single
  `write()`, but POSIX does not guarantee an all-or-nothing write to a regular file
  — a kill can land mid-write. With one frame per event, that loses the *tail* of a
  batch and keeps its head, so a turn could be half-recorded. With the batch as one
  frame, a partial write leaves a short tail that replay discards whole: a turn is
  recovered completely or not at all.

  ## Why an append-only file is the *strongest* option here, not the laziest

  A killed process is routine in this app, not exceptional: it is how `cancel_turn`
  and the runaway-query kill switch both work, and `terminate/2` does not run on a
  `:kill`. So durability cannot depend on a clean shutdown — which is exactly what
  rules out DETS (whose default `auto_save` is 3 minutes, with repair-on-open after
  an unclean halt) and snapshot files (which can be caught mid-rewrite).

  An append with `:file.sync/1` has neither failure mode. A write killed halfway
  leaves a *short tail*: either fewer than four bytes of length prefix, or a length
  prefix promising more bytes than exist. Both are unambiguously "the last write did
  not finish", so replay stops there and every earlier record is intact. That is
  why `replay/1` treating a decode failure as end-of-log is the correct reading of a
  torn tail rather than silent data loss — and why it distinguishes a short tail
  (expected, logged at debug) from a truncated middle (corruption, logged loudly).

  ## Options

    * `:dir` — directory holding the logs (default `"data"`), created by `setup/1`.
    * `:sync` — `fsync` after each append (default `true`). This is the durability
      knob: with it off an append can sit in the page cache, so a machine crash —
      not a process crash — can lose the tail. One fsync per turn is the cost.
  """
  @behaviour Manifold.Store

  require Logger

  @version 1

  # Conversation ids arrive from the client (`open {conversation_id}`), so they are
  # untrusted input that is about to become a path. Anything outside this set is
  # refused rather than sanitised: a silently rewritten id would open one
  # conversation under another's name.
  @id_format ~r/^[A-Za-z0-9_-]{1,128}$/

  @impl true
  def setup(opts) do
    case File.mkdir_p(dir(opts)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir, dir(opts), reason}}
    end
  end

  @impl true
  def open(id, opts) do
    with :ok <- validate(id),
         path = path(id, opts),
         fresh? = not File.exists?(path),
         {:ok, fd} <- :file.open(String.to_charlist(path), [:append, :binary, :raw]) do
      handle = %{fd: fd, path: path, sync?: Keyword.get(opts, :sync, true)}

      if fresh? do
        case write(handle, {:manifold_log, @version}) do
          :ok -> {:ok, handle}
          {:error, reason} -> :file.close(fd) && {:error, reason}
        end
      else
        {:ok, handle}
      end
    end
  end

  @impl true
  def append(handle, events), do: write(handle, events)

  @impl true
  def replay(%{path: path}) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, decode(bytes, path)}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def close(%{fd: fd}), do: :file.close(fd) && :ok

  @impl true
  def delete(id, opts) do
    with :ok <- validate(id) do
      case File.rm(path(id, opts)) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def list(opts) do
    case File.ls(dir(opts)) do
      {:ok, entries} ->
        {:ok, entries |> Enum.filter(&String.ends_with?(&1, ".log")) |> Enum.map(&Path.rootname/1)}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- writing ---------------------------------------------------------------

  # One frame, one write, one fsync per batch — see the moduledoc on why the batch
  # must be a single frame rather than one frame per event.
  defp write(%{fd: fd, sync?: sync?}, term) do
    bin = :erlang.term_to_binary(term)

    with :ok <- :file.write(fd, [<<byte_size(bin)::32>>, bin]) do
      if sync?, do: :file.sync(fd), else: :ok
    end
  end

  # --- reading ---------------------------------------------------------------

  defp decode(bytes, path) do
    {events, rest} = decode(bytes, [], path)

    case rest do
      <<>> ->
        :ok

      tail ->
        Logger.debug("[store] #{path}: ignoring #{byte_size(tail)}-byte partial tail (a write was interrupted)")
    end

    case events do
      # Each frame after the header is a batch, so flatten them back into one
      # stream of events in the order they were appended.
      [{:manifold_log, @version} | batches] ->
        Enum.concat(batches)

      [{:manifold_log, other} | _] ->
        Logger.error("[store] #{path}: log version #{inspect(other)}, this build reads #{@version} — ignoring")
        []

      [] ->
        []

      _no_header ->
        Logger.error("[store] #{path}: missing log header — ignoring, refusing to guess the format")
        []
    end
  end

  defp decode(<<size::32, body::binary-size(size), rest::binary>>, acc, path) do
    # `:safe` refuses to *create* atoms, so a corrupt or hostile frame cannot grow
    # the atom table. Every atom these terms contain already exists in the code
    # that wrote them.
    case safe_term(body) do
      {:ok, term} ->
        decode(rest, [term | acc], path)

      :error ->
        # A frame that is complete but undecodable is corruption, not an
        # interrupted write — say so loudly, and stop rather than skip, because
        # everything after it is of unknown alignment.
        Logger.error("[store] #{path}: undecodable frame, #{byte_size(rest)} bytes after it abandoned")
        {Enum.reverse(acc), <<>>}
    end
  end

  defp decode(rest, acc, _path), do: {Enum.reverse(acc), rest}

  defp safe_term(body) do
    {:ok, :erlang.binary_to_term(body, [:safe])}
  rescue
    ArgumentError -> :error
  end

  # --- paths -----------------------------------------------------------------

  defp validate(id) do
    if Regex.match?(@id_format, id), do: :ok, else: {:error, {:unsafe_conversation_id, id}}
  end

  defp dir(opts), do: Keyword.get(opts, :dir, "data")
  defp path(id, opts), do: Path.join(dir(opts), id <> ".log")
end
