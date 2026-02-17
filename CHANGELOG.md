# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-02-18

### Added
- **GitHub Issue collector**: Fetches full comments via `/issues/{number}/comments` for each notable issue/PR; body now includes description + full discussion before AI summarization
- **RSS enrichment**: Entries linking to Redmine (bugs.ruby-lang.org/issues/{id}) or GitHub (issues/PRs) are enriched with full content + comments/journals via API before summarization
- **RedmineEnricher**: Fetches issue + journals from Redmine REST API for Ruby Bug Tracker entries
- **GitHubEnricher**: Fetches issue/PR + comments for GitHub-linked RSS entries
- **Deep PR crawl flag**: `DEEP_PR_CRAWL` can disable PR compare/linked PR deep crawling for faster dry runs and experiments
- **Run-level API cache**: In-memory cache avoids duplicate fetches for issue/PR meta, PR files, and comments during the same run
- **Cache hit visibility**: Logs now show `[cache-hit]` entries with namespace/key and value summary

### Changed
- **Processor**: Per-item body truncation increased from 200 to 800 chars to accommodate enriched comment content
- **PostgreSQL / Redis (devops)**: Focus on version releases and security only; add PostgreSQL (server) GitHub releases, remove Planet PostgreSQL RSS (too detailed), remove Redis from github_issues
- **Lookback window**: `LOOKBACK_DAYS` now uses full-day boundaries in TPE (UTC+8), from N days ago `00:00` to `now`
- **AI retry policy**: Retry up to 3 times on any processing error per category; fallback only after retries are exhausted
- **AI pacing**: Category-to-category delay reduced from 15 seconds to 5 seconds
- **Reference extraction**: Tightened GitHub reference detection to avoid false positives (for example, non-GitHub tracker IDs in release/issue text)
- **Documentation sync**: Updated README, `.env.example`, and docs (`CONTRIBUTING`/`PLAN`) for `DEEP_PR_CRAWL`, TPE full-day lookback semantics, and AI retry behavior

### Fixed
- **Nginx false references**: Avoid repeated 404 noise when non-GitHub `#number` tokens are mistakenly treated as GitHub issue/PR references
- **AI failure observability**: Retry and final-failure logs now include error class, reason, and short backtrace

## [0.1.5] - 2026-02-18

### Fixed

- **OpenAI processor**: Use `max_completion_tokens` instead of `max_tokens` for models that require it (GPT-5.x, o1, o3); fixes 400 error "Unsupported parameter: 'max_tokens'"

### Added

- **OpenAI processor**: Auto-detect models needing `max_completion_tokens`; `AI_USE_MAX_COMPLETION_TOKENS=true` env override for manual control

## [0.1.4] - 2026-02-17

### Fixed

- BCC: Mail gem omits Bcc from encoded output by default; inject Bcc header into raw payload so Gmail API delivers to BCC recipients

### Changed

- **Prompt (category_digest)**: Technical details section must state concrete problem, trigger scenario, and compatibility impact; no vague phrasing; recommended actions section must include syntax changes, deprecated replacements, developer watch items, and code blocks—not just version upgrade
- **Prompt (category_digest)**: Restructure for AI readability (sections, table, MUST/MUST NOT, remove redundancy)

### Added

- **Digest template**: `format_summary_content` converts ``` code blocks to `<code class="summary-code">`; `.summary-code` CSS prevents overflow (`white-space: pre-wrap`, `word-break`, `overflow-x`)
- **TemplateRenderer**: `escape_html` (CGI.escapeHTML) for XSS prevention; `format_summary_content` converts markdown code blocks to HTML with proper escaping

## [0.1.3] - 2026-02-16

### Changed

- Digest limits: each category up to 10 candidates; releases + others display capped at 7 per category; bypass 7-item cap when all items are critical/high (show up to 10)
- Backend section: Ruby-centric; Go items only when major/significant or security-related
- GitHub Actions: `actions/checkout@v5` → `actions/checkout@v6`

### Added

- Official security RSS feeds: Node.js Security Advisories, Rails Security Announcements, Kubernetes Official CVE Feed, HashiCorp Security Bulletins
- BCC support (`EMAIL_BCC`, optional)
- Go language in backend: GitHub releases, issues, The Go Blog (go.dev)
- Frontend: TypeScript (releases, issues, npm advisory)
- DevOps: PostgreSQL News & Releases (Planet PostgreSQL RSS), Redis (server), Helm, Grafana, ArgoCD, Docker Engine (moby/moby), Reloader (stakater)
- Amazon EKS: Kubernetes version lifecycle doc feed (`amazon-eks-user-guide` commit atom for versioning page)
- Backend: Doorkeeper, Devise (OAuth, auth gems)

## [0.1.2] - 2026-02-14

### Added

- `docs/` folder: CONTRIBUTING, PLAN, GMAIL_OAUTH_SETUP, GITHUB_ACTIONS, PROMPT_GUIDELINES, SECURITY
- `SECURITY.md` in root for vulnerability reporting
- Multiple recipients for `EMAIL_TO` (comma or semicolon separated)

### Changed

- All docs and README translated to English

## [0.1.1] - 2026-02-14

### Added

- DevOps GitHub Advisories: Go ecosystem (containerd, runc, Kubernetes, Terraform, Docker CLI)
- Framework/package badge for "other updates" items to clarify which framework/language/package each item relates to

### Changed

- **Prompt**: More detailed summary structure (2-4 sentences per block for key points / technical details / recommended actions)
- **Prompt**: Release blocks must list 2-3 concrete developer-facing items
- **Prompt**: PR/Issue summaries focus on problem, debate/controversy, and final conclusion
- **Prompt**: Always highlight API/function changes (input/output, deprecated, sunset)
- **Prompt**: Add `framework_or_package` field for advisory/issue/other items
- **GitHub Actions**: `GITHUB_TOKEN` fallback to `github.token` when `GH_PAT_TOKEN` not set
- **GitHub Actions**: `AI_PROVIDER` default to `gemini` when not set
- **README**: Update clone URL, project structure, DevOps security sources

## [0.1.0] - 2026-02-13

### Added

- Digest pipeline: collectors (GitHub Releases, Issues, RSS, RubyGems, GitHub Advisories)
- AI processors: Gemini and OpenAI-compatible APIs (OpenRouter, Groq, Ollama)
- Gmail API notifier with OAuth 2.0 refresh token (no SMTP password)
- CLI: `bin/generate_digest` with `DRY_RUN` preview support
- GitHub Actions workflow: weekly digest every Monday 08:00 (UTC+8)
- Comprehensive README with architecture, setup, and configuration guide

### Fixed

- Gmail API send: avoid double base64 encode (google-apis-gmail_v1 encodes automatically)
- Add EMAIL_TO/EMAIL_FROM validation before send
- Add text_part for multipart/alternative structure (Gmail compatible)

### Changed

- Use `actions/checkout@v5` in GitHub Actions workflow

[Unreleased]: https://github.com/william-eth/web_tech_feeder/compare/1.0.0...HEAD
[1.0.0]: https://github.com/william-eth/web_tech_feeder/compare/0.1.5...1.0.0
[0.1.5]: https://github.com/william-eth/web_tech_feeder/compare/0.1.4...0.1.5
[0.1.4]: https://github.com/william-eth/web_tech_feeder/compare/0.1.3...0.1.4
[0.1.3]: https://github.com/william-eth/web_tech_feeder/compare/0.1.2...0.1.3
[0.1.2]: https://github.com/william-eth/web_tech_feeder/compare/0.1.1...0.1.2
[0.1.1]: https://github.com/william-eth/web_tech_feeder/compare/0.1.0...0.1.1
[0.1.0]: https://github.com/william-eth/web_tech_feeder/compare/a4d0ccd...0.1.0
