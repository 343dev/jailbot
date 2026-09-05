# AGENTS.md

## Commands

- Run tests with `./test_jailbot.sh`; they stub the `docker` binary, so no Docker daemon is required.
- Before considering a task complete, run `./test_jailbot.sh` and make sure it passes.

## Code conventions

- Shell scripts (`jailbot.sh`, `docker-example/entrypoint.sh`, `test_jailbot.sh`) must stay POSIX `sh` — no bashisms such as arrays or `[[ ]]`.
- Tests are process-level contract tests asserting the exact `docker` argv; add new tests in `test_jailbot.sh` following the existing `run_test` pattern.

## Agent skills

### Issue tracker

Issues are tracked as local markdown files under `.scratch/<feature>/`. See `docs/agents/issue-tracker.md`.

### Domain docs

This repository uses the single-context domain-doc layout. See `docs/agents/domain.md`.
