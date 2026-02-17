# Contributing Guide

## Project Structure

```
lib/
├── web_tech_feeder.rb    # Main orchestrator
├── config.rb             # Environment and configuration
├── sources.yml           # Data sources (GitHub releases/issues, RSS, advisories)
├── collectors/           # Data collectors
├── processor/            # AI summarization (Gemini / OpenAI)
├── prompts/              # AI prompt templates
├── notifier/             # Gmail API sender
└── templates/            # HTML email templates
```

## Key Files

| File | Purpose |
|------|---------|
| `lib/sources.yml` | Add or modify data sources (repos, RSS, advisories) |
| `lib/prompts/category_digest.erb` | AI summary format and rules |
| `lib/templates/digest.html.erb` | Email layout, subsections, badges |
| `.env.example` | Environment variable template |
| `docs/` | Documentation |

## Development Workflow

```bash
# Install
bundle install

# Preview (no email, outputs tmp/digest_preview.html)
DRY_RUN=true bundle exec ruby bin/generate_digest

# Send email
bundle exec ruby bin/generate_digest
```

### Useful Runtime Toggles

- `LOOKBACK_DAYS=7`: Full-day window in TPE (UTC+8), from N days ago `00:00` to `now`
- `DEEP_PR_CRAWL=false`: Skip PR compare and linked-PR deep crawling for faster experiments
- `DRY_RUN=true`: Render preview only, no email delivery

### AI Retry Behavior

- AI processing retries up to 3 times per category on any processing error
- Category-to-category wait is 5 seconds
- If all retries fail, the category falls back to deterministic non-AI summary output

## Adding Data Sources

1. Edit `lib/sources.yml`
2. Add entries for: `github_releases`, `github_issues`, `rss_feeds`, `rubygems`, `github_advisories`
3. For `github_advisories`, specify `ecosystem` (npm, rubygems, go) and `packages` array

## Modifying Digest Output

- Summary format: `lib/prompts/category_digest.erb`
- Layout and structure: `lib/templates/digest.html.erb`
- Filtering logic: `lib/web_tech_feeder.rb` — `filter_by_importance`, `DigestLimits`

## Related Documentation

- [Design & Implementation Plan](PLAN.md)
- [Gmail OAuth Setup](GMAIL_OAUTH_SETUP.md)
- [GitHub Actions](GITHUB_ACTIONS.md)
- [Prompt Guidelines](PROMPT_GUIDELINES.md)
- [Security Policy](SECURITY.md)
