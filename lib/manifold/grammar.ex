defmodule Manifold.Grammar do
  @moduledoc """
  GBNF grammars for constrained decoding, embedded at compile time.

  Pass `Manifold.Grammar.prolog/0` as the `:grammar` option to
  `Manifold.Llama.Client.completion/2` to force the model's output to be
  syntactically valid Prolog.
  """
  @prolog_path Path.join([__DIR__, "..", "..", "priv", "grammar", "prolog.gbnf"])
  @external_resource @prolog_path
  @prolog File.read!(@prolog_path)

  @doc "GBNF grammar for a useful subset of Prolog (facts, rules, negation-as-failure)."
  @spec prolog() :: String.t()
  def prolog, do: @prolog
end
