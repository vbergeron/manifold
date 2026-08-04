defmodule Manifold.Clause do
  @moduledoc """
  Text-level handling of the Prolog clauses that flow between the model, the KB,
  and the UI's left panel.

  The GBNF grammar (`Manifold.Grammar.prolog/0`) already guarantees the model's
  output is syntactically valid, so this module never has to *validate* — only
  segment (`split/1`), classify (`kind/1`, the protocol's `fact | rule |
  constraint`), and describe (`signatures/1`, which feeds the known-predicate
  list back into the next turn's prompt so vocabulary doesn't drift).

  Canonical clause text carries its trailing period (that is what the UI shows);
  `body/1` strips it for the forms MQI wants — `assertz((Body))` and `run(Goal)`.
  """

  @doc """
  Split a blob of Prolog source into canonical clause texts (period included).

  Splits on a period followed by whitespace or end-of-input, so decimals inside
  numbers survive; anything with unbalanced parentheses is dropped as truncated
  output (`n_predict` can cut the model off mid-clause).
  """
  @spec split(String.t()) :: [String.t()]
  def split(source) do
    source
    |> String.split(~r/\.(?=\s|$)/)
    |> Enum.map(&normalize/1)
    |> Enum.reject(&(&1 == "." or not balanced?(&1)))
  end

  @doc "Canonical form: whitespace collapsed, exactly one trailing period."
  @spec normalize(String.t()) :: String.t()
  def normalize(text) do
    text
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
    |> String.trim_trailing(".")
    |> String.trim()
    |> Kernel.<>(".")
  end

  @doc "The clause without its trailing period — the form `assertz`/`run` take."
  @spec body(String.t()) :: String.t()
  def body(text), do: text |> String.trim() |> String.trim_trailing(".") |> String.trim()

  @doc """
  Classify a clause. A headless `:- Body` is an integrity constraint (manifold's
  representation of negation), `Head :- Body` a rule, anything else a fact.
  """
  @spec kind(String.t()) :: :fact | :rule | :constraint
  def kind(text) do
    text = String.trim(text)

    cond do
      String.starts_with?(text, ":-") -> :constraint
      String.contains?(text, ":-") -> :rule
      true -> :fact
    end
  end

  @doc """
  The goal of a `:- Body` constraint — the query whose *success* is a
  contradiction. Returns `nil` for facts and rules.
  """
  @spec constraint_goal(String.t()) :: String.t() | nil
  def constraint_goal(text) do
    case kind(text) do
      :constraint -> text |> body() |> String.trim_leading(":-") |> String.trim()
      _ -> nil
    end
  end

  @doc """
  The distinct variables a clause mentions, in order of first appearance.

  `_` counts: it is an anonymous variable, not a wildcard that means "unknown".
  The lookbehind is what keeps `has_beak` and `pet1` from reading as variables —
  only an upper-case letter or underscore *starting* a token is one.
  """
  @spec variables(String.t()) :: [String.t()]
  def variables(text) do
    ~r/(?<![a-zA-Z0-9_])[A-Z_][a-zA-Z0-9_]*/
    |> Regex.scan(text)
    |> Enum.map(fn [v] -> v end)
    |> Enum.uniq()
  end

  @doc """
  Why `text` must not be asserted, or `nil` if it is safe.

  The GBNF grammar guarantees *syntax*, not sense, and there is one unsound shape
  it cannot exclude: a **fact carrying a variable**. `pet(jane, _).` does not say
  "Jane has some pet" — it makes `pet(jane, X)` succeed for *every* `X`, so a
  single such clause renders every later query about that predicate meaningless
  while still looking like a normal fact in the KB.

  Extraction produces these whenever the model refers to something it cannot name
  ("Kelly's pet"), which is exactly when it is least able to notice the damage.
  So they are refused here instead of asserted.

  Rules and constraints are variable-bearing by nature (`mortal(X) :- human(X).`,
  `:- whale(A), fish(A).`) — there the variable is bound by the body, which is the
  whole point, and they are never rejected.
  """
  @spec rejection(String.t()) :: String.t() | nil
  def rejection(text) do
    case {kind(text), variables(text)} do
      {:fact, [_ | _] = vars} ->
        "a fact may not contain variables (#{Enum.join(vars, ", ")}): it would hold for every term"

      _ ->
        nil
    end
  end

  @doc """
  The `"name/arity"` signatures a clause mentions: the head for facts and rules,
  every top-level body goal for a constraint (which has no head).
  """
  @spec signatures(String.t()) :: [String.t()]
  def signatures(text) do
    case kind(text) do
      :constraint ->
        text |> constraint_goal() |> split_top_level() |> Enum.map(&signature/1)

      :rule ->
        [text |> body() |> String.split(":-", parts: 2) |> hd() |> signature()]

      :fact ->
        [text |> body() |> signature()]
    end
    |> Enum.reject(&is_nil/1)
  end

  # `human(socrates)` -> "human/1"; a bare atom -> "raining/0"; junk -> nil.
  #
  # A leading `\+` is the negation operator wrapping a goal, not part of the
  # predicate's name: the signature of `\+ flies(tweety)` is `flies/1`. Without
  # this the whole term fails to parse and the goal reports *no* predicates, which
  # would let it slip past any check made against the KB's known ones.
  defp signature(term) do
    term = term |> String.trim() |> String.replace_prefix("\\+", "")

    case Regex.run(~r/^\s*([a-z][a-zA-Z0-9_]*)\s*(\(.*\))?\s*$/s, term) do
      [_, name] -> "#{name}/0"
      [_, name, args] -> "#{name}/#{args |> inner() |> split_top_level() |> length()}"
      _ -> nil
    end
  end

  # Contents of the outermost parentheses of "(A, f(B, C))".
  defp inner(args), do: args |> String.trim() |> binary_slice(1..-2//1)

  # Split on commas nested inside neither parentheses nor brackets. Brackets have
  # to count too, or the comma in `member(X, [a, b])` splits an argument in half
  # and the goal reads as `member/3`.
  defp split_top_level(nil), do: []

  defp split_top_level(text) do
    {parts, last, _depth} =
      text
      |> String.graphemes()
      |> Enum.reduce({[], "", 0}, fn
        ch, {parts, cur, d} when ch in ["(", "["] -> {parts, cur <> ch, d + 1}
        ch, {parts, cur, d} when ch in [")", "]"] -> {parts, cur <> ch, d - 1}
        ",", {parts, cur, 0} -> {[cur | parts], "", 0}
        ch, {parts, cur, d} -> {parts, cur <> ch, d}
      end)

    [last | parts] |> Enum.reverse() |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  # A stack rather than a counter, because the two bracket kinds must also *match*:
  # `foo([a, b).` balances by count and would otherwise survive as valid.
  defp balanced?(text) do
    text
    |> String.graphemes()
    |> Enum.reduce_while([], fn
      "(", stack -> {:cont, [")" | stack]}
      "[", stack -> {:cont, ["]" | stack]}
      ch, [ch | rest] when ch in [")", "]"] -> {:cont, rest}
      ch, _stack when ch in [")", "]"] -> {:halt, :unbalanced}
      _, stack -> {:cont, stack}
    end)
    |> Kernel.==([])
  end
end
