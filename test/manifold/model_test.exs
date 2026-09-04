defmodule Manifold.ModelTest do
  use ExUnit.Case, async: false

  alias Manifold.Model

  # Pure: no OS process, no network. Just the delegation seam itself — that the
  # configured module is the one actually called, that its opts travel alongside it,
  # and that the default matches what config/config.exs ships.

  defmodule Fake do
    @behaviour Manifold.Model

    @impl Manifold.Model
    def completion(prompt, opts), do: {:ok, "completion: #{prompt} #{inspect(opts)}"}

    @impl Manifold.Model
    def stream(prompt, _opts, on_delta) do
      on_delta.(prompt)
      {:ok, prompt}
    end
  end

  test "defaults to Manifold.Llama.Client" do
    assert Model.impl() == Manifold.Llama.Client
  end

  test "opts/0 carries the default backend's local-hosting config" do
    opts = Model.opts()
    assert Keyword.has_key?(opts, :model_path)
    assert Keyword.has_key?(opts, :llama_host)
    assert Keyword.has_key?(opts, :llama_port)
  end

  test "impl/0 and opts/0 read a {module, opts} tuple" do
    with_model({Fake, provider_specific: true}, fn ->
      assert Model.impl() == Fake
      assert Model.opts() == [provider_specific: true]
    end)
  end

  test "a bare module atom is accepted with empty opts, for tests that don't care about opts" do
    with_model(Fake, fn ->
      assert Model.impl() == Fake
      assert Model.opts() == []
    end)
  end

  test "completion/2 delegates to the configured backend" do
    with_model(Fake, fn ->
      assert Model.completion("hi", n_predict: 1) == {:ok, "completion: hi [n_predict: 1]"}
    end)
  end

  test "stream/3 delegates to the configured backend" do
    with_model(Fake, fn ->
      on_delta = fn chunk -> send(self(), {:delta, chunk}) end

      assert Model.stream("hi", [], on_delta) == {:ok, "hi"}
      assert_received {:delta, "hi"}
    end)
  end

  defp with_model(config, fun) do
    previous = Application.get_env(:manifold, :model)
    Application.put_env(:manifold, :model, config)

    try do
      fun.()
    after
      if previous, do: Application.put_env(:manifold, :model, previous), else: Application.delete_env(:manifold, :model)
    end
  end
end
