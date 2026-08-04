[
  # `scripts/` is deliberately left out: those are one-off harnesses written with
  # compact one-liners that the formatter would blow up into paragraphs.
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  # Plug exports `locals_without_parens` for the router DSL, so `plug :match` and
  # `get "/health" do` are left alone instead of being given parentheses.
  import_deps: [:plug],
  # The code is written wider than the 98-column default; this is the width it is
  # actually in, so `mix format` is a no-op rather than a reflow of every file.
  line_length: 120
]
