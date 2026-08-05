# Working in this repository

## The three test tiers, and why they are separate

```
test/manifold/      pure. no OS process. runs everywhere, always.
test/integration/   @moduletag :swipl — a real engine, no model.
test/smoke/         @moduletag :smoke — EXCLUDED from `mix test`.
```

```sh
mix test                                   # tiers 1 + 2. the everyday command
mix test --exclude swipl                   # tier 1 only, on a box without SWI-Prolog
mix test test/smoke/engine_cost_test.exs   # ONE assumption
mix test --only smoke                      # all of them — see below
```

**Smoke tests verify one-shot assumptions about the world outside this codebase.** What
SWI-Prolog does, what MQI guarantees, what an OS process costs. They are *not* correctness
tests, and they are excluded from `mix test` deliberately.

Run **one** when you need to confirm **one** assumption, and name the assumption in the
test — every file in `test/smoke/` opens with `ASSUMPTION:` and carries the measured value
in its moduledoc. Running the whole set is **exceptional**: it belongs to a SWI-Prolog
upgrade, a new machine, or a suspicion that something outside the code has changed. It does
not belong to a normal change.

The reason is not merely that they are slow. A suite you run wholesale on every change is a
suite you learn to skim, and these are the tests whose failure means a premise of the
architecture has moved — the one signal that must never be background noise.

Correctness belongs in `test/manifold` (pure) or `test/integration` (needs an engine).
**Never add a correctness assertion to a smoke test**, and never add an assumption probe to
the other two tiers.

`test/smoke/prolog_autoload_test.exs` is a special case worth knowing about: it asserts
*broken* behaviour on purpose, so that whoever fixes the bug is told by a failing test.

## Tests are hermetic, on purpose

`config/runtime.exs` is skipped under `:test`, so `MANIFOLD_*` in your shell — and
`mise.toml [env]`, which sets `MANIFOLD_MODEL` — cannot reach a test run. Configuration
comes from `config/test.exs` and nowhere else. That file also:

- serves on **4001**, so a dev server on 4000 never collides with the suite;
- sets `store: Manifold.Store.None`, so no test writes into `data/`. A test that needs
  persistence points `:store` at a temp directory **and creates it** — `Store.setup/0` only
  runs at boot, and `Store.Log.open/2` on a missing directory degrades silently to the null
  store;
- points `model_path` at a file that does not exist. This is load-bearing rather than merely
  fast: `Llama.Server` then parks in `:no_model` without spawning, but still answers
  `endpoint/0`, so `Llama.Client` returns a real `{:error, _}` instead of exiting `:noproc` —
  which is what makes the no-model fallback testable.

## Writing tests here

- **Assert prompt *properties*, never exact prompt text.** The prompts in `Manifold.Prompt`
  are iterated constantly; a test pinned to their wording fails on every improvement while
  telling you nothing.
- **Do not compare whole event envelopes.** `Manifold.Event.new/3` stamps wall-clock time.
- **Count solutions when checking for duplicates.** A doubled knowledge base still answers
  `true` to everything it answered `true` to before, which is exactly how a real duplication
  bug went unnoticed. And `aggregate_all/3` cannot be used — see the autoload test.
- **Use `Manifold.EngineCase` for anything needing an engine.** It stops every conversation
  it opens in `on_exit`; a leaked conversation is a leaked OS process for the rest of the run.
- Prefer `eventually/2` over `Process.sleep` for genuinely asynchronous edges — an OS process
  dying, a supervisor noticing.

## `scripts/` is not the test suite

`scripts/gen.exs` and `scripts/prompt_eval.exs` are **exploratory model harnesses** with no
assertions by design: they generate under the grammar and print what came back, for a human
to judge. `prompt_eval.exs` runs nine serialised generations, which is minutes on CPU. They
are for iterating on prompts, not for verifying anything.
