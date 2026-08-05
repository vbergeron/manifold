#!/bin/bash
# Provisions Erlang, Elixir, and SWI-Prolog in Claude Code cloud sessions so `mix test`
# (tiers 1 + 2, see CLAUDE.md) can run there. No-op locally: your machine already has
# these via `mise install` (see mise.toml / README.md "Toolchain (via mise)").
#
# Why this doesn't just use mise: mise's own installer (mise.run, mise.jdx.dev,
# repo.mise.jdx.dev) is not on this environment's network allowlist. Everything below
# instead comes from hosts that ARE allowlisted under "Trusted" network access:
# archive.ubuntu.com (apt) and github.com.
#
# The one thing that is NOT reachable under "Trusted" is repo.hex.pm, which `mix
# deps.get` needs to fetch this project's Hex packages (req, jason, bandit,
# websock_adapter, plug). If that step fails below, add `repo.hex.pm` to this
# environment's Custom allowed domains (claude.ai/code -> environment settings) —
# everything else here works around the allowlist gap already.
set -uo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# Async: the session starts immediately while this installs in the background. A tool
# call that runs before this finishes (elixir/mix/swipl, or anything under
# CLAUDE_PROJECT_DIR that needs deps compiled) will fail until it completes — see
# asyncTimeout below for the outside bound on how long that window can be.
echo '{"async": true, "asyncTimeout": 300000}'

ELIXIR_VERSION=1.18.4
OTP_SERIES=25 # matches Ubuntu 24.04's `apt install erlang` (25.3.x); see note below.
ELIXIR_HOME=/opt/elixir
REBAR3_TAG=3.23.0

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# --- Erlang + SWI-Prolog: plain apt packages, both hosts are Trusted-allowlisted. ---
# NOTE: mise.toml pins erlang 27 for local dev; apt only has 25 (Ubuntu 24.04 universe).
# Elixir 1.18 supports OTP 25-27, so this still runs the real test suite — just not on
# the exact OTP minor CI uses. If that ever matters, build OTP 27 from source instead.
if ! command -v erl >/dev/null 2>&1 || ! command -v swipl >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq erlang swi-prolog locales
fi

# --- Elixir: precompiled zip from a GitHub release (github.com is Trusted-allowlisted).
# The zip is plain compiled .beam files, no build step, just match it to the OTP series
# installed above.
if [ ! -x "$ELIXIR_HOME/bin/elixir" ]; then
  mkdir -p "$ELIXIR_HOME"
  curl -fsSL -o /tmp/elixir.zip \
    "https://github.com/elixir-lang/elixir/releases/download/v${ELIXIR_VERSION}/elixir-otp-${OTP_SERIES}.zip"
  unzip -q -o /tmp/elixir.zip -d "$ELIXIR_HOME"
fi

export PATH="$ELIXIR_HOME/bin:$PATH"
export MIX_HOME="$ELIXIR_HOME/.mix"
export HEX_HOME="$ELIXIR_HOME/.hex"

# --- Hex: installed from its GitHub source, not the usual `mix local.hex` (which hits
# builds.hex.pm — not Trusted-allowlisted). Compiling it locally only needs github.com.
if ! ls "$MIX_HOME"/archives/hex-* >/dev/null 2>&1; then
  mix archive.install github hexpm/hex branch latest --force
fi

# --- rebar3: same problem as Hex (`mix local.rebar` hits builds.hex.pm). Built from
# source instead — rebar3's own deps are vendored, so this only needs github.com too.
REBAR3_BIN="$MIX_HOME/rebar3"
if [ ! -x "$REBAR3_BIN" ]; then
  rm -rf /tmp/rebar3-src
  git clone --depth 1 --branch "$REBAR3_TAG" https://github.com/erlang/rebar3.git /tmp/rebar3-src
  (cd /tmp/rebar3-src && ./bootstrap)
  cp /tmp/rebar3-src/rebar3 "$REBAR3_BIN"
  chmod +x "$REBAR3_BIN"
  mix local.rebar rebar3 "$REBAR3_BIN" --force
fi

# Persist toolchain PATH/env for every later Bash call this session makes.
{
  echo "export PATH=\"$ELIXIR_HOME/bin:\$PATH\""
  echo "export MIX_HOME=\"$MIX_HOME\""
  echo "export HEX_HOME=\"$HEX_HOME\""
  echo "export LANG=C.UTF-8"
  echo "export LC_ALL=C.UTF-8"
} >>"$CLAUDE_ENV_FILE"

# --- Project deps: the one step that needs a domain outside the default allowlist. ---
cd "$CLAUDE_PROJECT_DIR"
if mix deps.get >/tmp/deps-get.log 2>&1; then
  mix compile >/tmp/compile.log 2>&1 || cat /tmp/compile.log >&2
else
  {
    echo "mix deps.get could not reach the Hex package repository."
    echo "Add 'repo.hex.pm' to this environment's Custom allowed domains"
    echo "(claude.ai/code -> environment settings -> Network access) and restart the session."
    echo "--- mix deps.get output ---"
    cat /tmp/deps-get.log
  } >&2
fi

exit 0
