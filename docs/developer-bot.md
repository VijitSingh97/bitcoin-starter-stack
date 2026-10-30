# Developer bot

Maintainers can run repository writes as the private GitHub App
`bitcoin-starter-stack-developer` without changing their normal `gh` login.

Register the App with webhooks disabled and only these repository permissions:

- Contents: read and write
- Metadata: read-only
- Pull requests: read and write
- Workflows: read and write

Install it for `VijitSingh97` with **Only select repositories** and select only
`bitcoin-starter-stack`. The owner then configures the helper with the App ID and
downloaded private key:

```bash
tools/developer-bot.py configure APP_ID /path/to/downloaded-key.pem
```

The helper copies the key outside Git to
`~/.config/bitcoin-starter-stack-developer/private-key.pem`; the directory is mode
`0700` and its key and config are mode `0600`. Delete the downloaded source key
after checking the configured helper. Set `BSS_DEVELOPER_BOT_CONFIG_DIR` to use a
different config directory. `BSS_DEVELOPER_BOT_APP_ID` and
`BSS_DEVELOPER_BOT_PRIVATE_KEY` can override the saved values; override files must
have the same private permissions.

Use the wrapper for authenticated writes and bot-attributed commits:

```bash
tools/developer-bot.py gh pr create --fill
tools/developer-bot.py git commit -m "Describe the change"
tools/developer-bot.py git push HEAD:my-branch
```

Each command mints a short-lived installation token limited to this repository
and verifies the App bot identity. `gh` receives it only in an isolated child
environment. Pushes use a fixed HTTPS repository URL, ignore configured credential
helpers and Git hooks, and never put the token in an argument. The wrapper has no
command that prints a token and does not change global Git or GitHub CLI settings.

Read-only bootstrap checks can continue to use ordinary `git` and unauthenticated
GitHub access. If the helper is not configured, stop before a repository write and
ask the owner for the App ID and local PEM path; do not fall back to a human token.
