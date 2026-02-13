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
