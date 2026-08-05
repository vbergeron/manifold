defmodule Manifold.Prolog.AuditTree do
  @moduledoc """
  Renders a `why/2` proof term (`priv/prelude.pl`) as an audit tree instead of
  the flattened Prolog source `Manifold.Prolog.Answer` produces for every other
  binding.

  A proof term is one of four shapes coming back from MQI as ordinary
  functor/args JSON:

      %{"functor" => "fact",    "args" => [Goal]}
      %{"functor" => "rule",    "args" => [Goal, ProofBody]}
      %{"functor" => "either",  "args" => [Side, ProofArm]}
      %{"functor" => "builtin", "args" => [Goal]}

  (`ProofBody` is itself a proof term, or — for a conjunction — a flat list of
  them; see the prelude's own header for why.) Nothing about this module knows
  the predicate is named `why`: it recognizes the *shape* of a proof, so any
  goal that hands one back — not only a literal `why(...)` call — gets the
  same treatment. That is what lets `Manifold.Turn` apply it uniformly to a
  question-mode query (the `?` prefix) and a goal the model generated itself:
  both just run a goal and get a `Manifold.Conversation.query/3` result back.
  """

  @infix ~w(> < >= =< =:= is = ==)

  @doc "Is `term` a why/2-shaped proof, or a flat list of them (a conjunction's body)?"
  @spec proof?(term()) :: boolean()
  def proof?(%{"functor" => "fact", "args" => [_goal]}), do: true
  def proof?(%{"functor" => "builtin", "args" => [_goal]}), do: true
  def proof?(%{"functor" => "either", "args" => [side, arm]}) when side in ["left", "right"],
    do: proof?(arm)

  def proof?(%{"functor" => "rule", "args" => [_goal, body]}), do: proof?(body)
  def proof?([_ | _] = list), do: Enum.all?(list, &proof?/1)
  def proof?(_), do: false

  @doc """
  Every proof term bound in `result` (a `Manifold.Conversation.query/3` success
  value), in the order its solutions came back. Empty for `true`, `false`, or
  bindings that are not shaped like a proof — which is the common case, and why
  this never fires for an ordinary query.
  """
  @spec proofs(term()) :: [term()]
  def proofs({:bindings, solutions}) do
    for solution <- solutions,
        %{"functor" => "=", "args" => [_var, value]} <- solution,
        proof?(value),
        do: value
  end

  def proofs(_), do: []

  @doc "Every proof term in `result`, already rendered as an audit tree."
  @spec audit(term()) :: [String.t()]
  def audit(result), do: result |> proofs() |> Enum.map(&render/1)

  @doc """
  Render one proof term as an audit tree: the goal it proves on top, its
  derivation beneath it, `tree`-style box-drawing connectors marking the last
  child at each level.
  """
  @spec render(term()) :: String.t()
  def render(proof), do: proof |> node() |> format() |> Enum.join("\n")

  # --- proof term -> {label, tag, children} -----------------------------------

  defp node(%{"functor" => "fact", "args" => [goal]}), do: {source(goal), "fact", []}
  defp node(%{"functor" => "builtin", "args" => [goal]}), do: {source(goal), "builtin", []}

  defp node(%{"functor" => "either", "args" => [side, arm]}),
    do: {"either (#{side})", :either, [node(arm)]}

  defp node(%{"functor" => "rule", "args" => [goal, body]}), do: {source(goal), "rule", body_nodes(body)}

  defp body_nodes(body) when is_list(body), do: Enum.map(body, &node/1)
  defp body_nodes(body), do: [node(body)]

  # --- {label, tag, children} -> lines -----------------------------------------

  defp format({label, tag, children}), do: [line(label, tag) | branches(children, "")]

  defp branches(children, prefix) do
    last = length(children) - 1

    children
    |> Enum.with_index()
    |> Enum.flat_map(fn {{label, tag, grandchildren}, i} ->
      last? = i == last
      connector = if last?, do: "└─ ", else: "├─ "
      pad = if last?, do: "   ", else: "│  "
      [prefix <> connector <> line(label, tag) | branches(grandchildren, prefix <> pad)]
    end)
  end

  # `either` names the arm in its label already (`either (right)`); tagging it
  # again as `[either]` would just repeat what the label already says.
  defp line(label, :either), do: label
  defp line(label, tag), do: "#{label}  [#{tag}]"

  # --- goal term -> Prolog source ----------------------------------------------

  defp source(%{"functor" => f, "args" => [a, b]}) when f in @infix, do: "#{source(a)} #{f} #{source(b)}"
  # Zero args is a plain atom, not `f()` — the same term Prolog itself prints bare.
  defp source(%{"functor" => f, "args" => []}), do: f
  defp source(%{"functor" => f, "args" => args}), do: "#{f}(#{Enum.map_join(args, ", ", &source/1)})"
  defp source(v) when is_binary(v) or is_number(v), do: to_string(v)
  defp source(v) when is_list(v), do: "[#{Enum.map_join(v, ", ", &source/1)}]"
  defp source(v), do: inspect(v)
end
