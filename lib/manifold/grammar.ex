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

  @gate_path Path.join([__DIR__, "..", "..", "priv", "grammar", "gate.gbnf"])
  @external_resource @gate_path
  @gate File.read!(@gate_path)

  @doc "GBNF grammar for a useful subset of Prolog (facts, rules, negation-as-failure)."
  @spec prolog() :: String.t()
  def prolog, do: @prolog

  @doc """
  GBNF grammar for the gate: `chitchat` | `statement` | `question`, one per
  sentence. Constraining the gate's output to three words is what makes a model
  call viable there — see `Manifold.Gate`.
  """
  @spec gate() :: String.t()
  def gate, do: @gate
end
