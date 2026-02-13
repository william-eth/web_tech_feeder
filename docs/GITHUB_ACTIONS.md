# GitHub Actions

## Secrets

Add these in `Settings > Secrets and variables > Actions`:

### Required

| Secret | Description |
|--------|-------------|
| `GMAIL_CLIENT_ID` | Google OAuth Client ID |
| `GMAIL_CLIENT_SECRET` | Google OAuth Client Secret |
| `GMAIL_REFRESH_TOKEN` | OAuth Refresh Token |
| `EMAIL_FROM` | Sender (must match OAuth-authorized account) |
| `EMAIL_TO` | Recipients (comma/semicolon separated for multiple) |

### AI (choose one)

**Gemini:**
- `GEMINI_API_KEY`

**OpenAI / OpenRouter / Groq:**
- `AI_PROVIDER` = `openai`
- `AI_API_URL`
- `AI_API_KEY`
- `AI_MODEL`

### Optional

| Secret | Description |
|--------|-------------|
| `GH_PAT_TOKEN` | GitHub Personal Access Token for higher API rate limits (5000/hr vs 60/hr) |

> **Note**: Do not create a secret named `GITHUB_TOKEN` (reserved by GitHub). The workflow uses `GH_PAT_TOKEN` and falls back to `github.token` when unset.

## Workflow Behavior

- **Schedule**: Every Monday 00:00 UTC (08:00 Taiwan)
- **Manual**: Actions tab → Run workflow
- **First run**: Execute manually at least once to activate the cron schedule

## Pushing Workflow Changes

If using a Personal Access Token for push, it must have the `workflow` scope, otherwise you will see:
`refusing to allow a Personal Access Token to create or update workflow without workflow scope`

Options:
1. Add `workflow` scope to your PAT
2. Use SSH for push: `git remote set-url origin git@github.com:owner/repo.git`
