defmodule Manifold.ModelTest do
  use ExUnit.Case, async: false

  alias Manifold.Model

  # Pure: no OS process, no network. Just the delegation seam itself — that the
  # configured module is the one actually called, and that the default matches
  # what config/config.exs ships.

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

  defp with_model(module, fun) do
    previous = Application.get_env(:manifold, :model)
    Application.put_env(:manifold, :model, module)

    try do
      fun.()
    after
      if previous, do: Application.put_env(:manifold, :model, previous), else: Application.delete_env(:manifold, :model)
    end
  end
end
