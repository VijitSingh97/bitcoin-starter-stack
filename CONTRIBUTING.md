# Contributing

Small stack, small rules. PRs welcome.

## Dev setup

```bash
git clone https://github.com/VijitSingh97/bitcoin-starter-stack.git
cd bitcoin-starter-stack
pip install -r build/dashboard/requirements.txt pytest
```

`shellcheck` and Docker are needed for the full test suite
(`sudo apt install shellcheck` / `brew install shellcheck`).

## Running tests

```bash
tests/run.sh
```

That runs shellcheck, the `configure.sh` end-to-end test, the
docker-compose contract test, and the dashboard unit tests. Anything the
machine can't run is skipped with a `SKIP:` line. CI
([.github/workflows/ci.yml](.github/workflows/ci.yml)) runs the same suite
plus a full image build on every push and PR.

## Ground rules

- Keep it minimal. This is a starter stack — prefer deleting over adding,
  and stdlib/native features over new dependencies.
- Every change to `configure.sh`, the compose file, or the dashboard needs
  a matching test in `tests/` or `build/dashboard/tests/`.
- No credentials or per-box values in tracked files. Anything user-specific
  flows through `config.json` → `.env` (gitignored).
- Docs live in [docs/](docs/) and must stay true — if a change makes a doc
  stale, fix the doc in the same PR.
