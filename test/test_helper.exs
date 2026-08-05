# Smoke tests are excluded here, not merely tagged, and that is the whole point of the
# separation: they verify assumptions about the world *outside* this codebase — what swipl
# does, what MQI guarantees, what an OS process costs — and they are slow. Running them
# wholesale on every change would train everyone to ignore them.
#
# Run one when you need to confirm one assumption:
#
#     mix test test/smoke/mqi_shared_db_test.exs
#
# See CLAUDE.md for the convention.
ExUnit.start(exclude: [:smoke])
