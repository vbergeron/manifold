defmodule Manifold.Prolog.Answer do
  @moduledoc """
  Shapes an `Manifold.Prolog.MQI.run/3` answer into the protocol's JSON
  `answer` value (`docs/PROTOCOL.md`): `true`, `false`, or
  `%{bindings: [%{"A" => "willy"}, …]}`.

  MQI hands us one solution as a list of `=`/2 binding objects
  (`%{"functor" => "=", "args" => ["A", "willy"]}`); the UI wants a plain
  variable→value map per solution. `witness/1` returns just the first one — the
  single counter-example a violated integrity constraint is rendered with.
  """

  @doc "Encode a `run/3` success value as the protocol's `answer`."
  @spec encode(term()) :: true | false | %{bindings: [map()]}
  def encode(true), do: true
  def encode(false), do: false
  def encode({:bindings, solutions}), do: %{bindings: Enum.map(solutions, &solution/1)}

  @doc "The first solution as a variable→value map, or `nil` if there is none."
  @spec witness(term()) :: map() | nil
  def witness({:bindings, [solution | _]}), do: solution(solution)
  def witness(_), do: nil

  defp solution(bindings) when is_list(bindings) do
    Map.new(bindings, fn
      %{"functor" => "=", "args" => [var, value]} -> {to_string(var), term(value)}
      other -> {"_", term(other)}
    end)
  end

  defp solution(other), do: %{"_" => term(other)}

  # Compound terms come back nested; flatten them to Prolog source so the UI can
  # print a witness without knowing MQI's JSON shape.
  defp term(value) when is_binary(value) or is_number(value), do: value
  defp term(%{"functor" => f, "args" => args}), do: "#{f}(#{Enum.map_join(args, ", ", &text/1)})"
  defp term(value) when is_list(value), do: Enum.map(value, &term/1)
  defp term(value), do: inspect(value)

  defp text(value), do: value |> term() |> to_string()
end
