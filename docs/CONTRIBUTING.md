# Contributing Guide

This document focuses on **developer workflow and implementation entrypoints**.
For user setup/run instructions, use the root `README.md`.
For architecture rationale and trade-offs, use `PLAN.md`.

## Project Structure

```
lib/
├── web_tech_feeder.rb    # Thin entrypoint
├── config.rb             # Environment and configuration
├── digest_limits.rb      # Shared digest limits
├── sources.yml           # Data sources (GitHub releases/issues, RSS, advisories)
├── services/             # Pipeline orchestration and digest shaping
├── collectors/           # Data collectors
├── github/               # Shared GitHub abstractions (client/reference/compare/context)
├── utils/                # Shared utilities (log/text/type/parallel)
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
| `lib/services/digest_pipeline.rb` | End-to-end pipeline orchestration |
| `lib/services/category_collector.rb` | Category/source collection orchestration |
| `lib/services/digest_filter.rb` | Post-AI filtering and release/other split |
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
- `COLLECT_PARALLEL=true`: Enable source/repo-level parallel collection (I/O-bound)
- `MAX_COLLECT_THREADS=4`: Source-level workers (defaults to 2 without GitHub token)
- `MAX_REPO_THREADS=3`: Repo-level workers in GitHub collectors (defaults to 2 without token)
- `VERBOSE_CID_LOGS=true`: Print run correlation id on verbose collector/client logs
- `VERBOSE_THREAD_LOGS=true`: Print thread id on verbose collector/client logs for parallel debugging
- `DRY_RUN=true`: Render preview only, no email delivery
- `RUBY_YJIT_ENABLE=1`: Enable YJIT locally (Ruby 3.1+) for better runtime performance

### AI Retry Behavior

- AI processing retries up to 3 times per category on any processing error
- Category-to-category wait is 5 seconds
- If all retries fail, the category falls back to deterministic non-AI summary output

## Adding Data Sources

1. Edit `lib/sources.yml`
2. Add entries for: `github_releases`, `github_issues`, `rss_feeds`, `rubygems`, `github_advisories`
3. For `github_advisories`, specify `ecosystem` (npm, rubygems, go) and `packages` array
4. For `github_releases`, optional per-repo controls:
   - `release_strategy`: `auto` (releases -> tags fallback), `releases_only`, `tags_only`
   - `release_notes_files`: extra changelog-like files to enrich sparse release/tag notes

## Modifying Digest Output

- Summary format: `lib/prompts/category_digest.erb`
- Layout and structure: `lib/templates/digest.html.erb`
- Filtering logic: `lib/services/digest_filter.rb`
- Pipeline orchestration: `lib/services/digest_pipeline.rb`
- Collection orchestration: `lib/services/category_collector.rb`
- Shared limits: `lib/digest_limits.rb`

## Related Documentation

- [Design & Implementation Plan](PLAN.md)
- [Gmail OAuth Setup](GMAIL_OAUTH_SETUP.md)
- [GitHub Actions](GITHUB_ACTIONS.md)
- [Prompt Guidelines](PROMPT_GUIDELINES.md)
- [Security Policy](SECURITY.md)
