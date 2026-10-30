# Repository agent instructions

- Keep this starter stack small and use standard-library or existing tools.
- Never put credentials or machine-specific values in tracked files.
- When `tools/developer-bot.py` is configured, use it for authenticated GitHub
  writes, commits, and pushes. Do not fall back to human credentials if it fails.
- Read-only Git and GitHub checks do not require the developer bot.
- Run the focused tests for every changed component and preserve peer edits.
