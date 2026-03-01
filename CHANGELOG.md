# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.1] - 2026-03-02

### Added
- **GitHub rate-limit telemetry**: Added `[gh-rate]` snapshots from response headers (`resource`, `remaining/limit`, `used`, `reset_at`, `retry_after`) and attached the same snapshot to rate-limit retry warnings for easier diagnosis.
- **Release-note domain enrichments**: Added `release_notes_domains` coverage for TypeScript (`devblogs.microsoft.com`), React (`react.dev`), and Argo CD (`argo-cd.readthedocs.io`, `blog.argoproj.io`) so release-body links can pull richer external context.

### Changed
- **External release-note strategy**: Removed `release_notes_urls` behavior and standardized external enrichment to release-body URL discovery + domain allowlist only.
- **Prompt actionability balance**: Updated `📊 建議動作` to support Action mode / Awareness mode, reducing forced commands when no immediate execution is needed while keeping concrete migration guidance when changes are required.
- **Code hint readability**: Prompt now prefers explicit fenced-code language tags (`ruby`, `ts`, `js`, `shell`, `yaml`) to improve downstream code presentation.

### Fixed
- **Summary code-block rendering**: Preserved line breaks during truncation and improved fenced-code parsing to avoid flattened one-line blocks in email output.
- **Language-aware code styling**: Added lightweight per-language code-block palettes (Ruby/TS/JS/Shell/YAML) with a safe fallback to improve scanability without full syntax-highlighting dependencies.

## [1.0.0] - 2026-02-18

### Added
- **GitHub Issue collector**: Fetches full comments via `/issues/{number}/comments` for each notable issue/PR; body now includes description + full discussion before AI summarization
- **RSS enrichment + enrichers**: Added API-based enrichment for RSS entries linking to Redmine/GitHub, powered by `RedmineEnricher` and `GitHubEnricher`
- **Shared GitHub abstractions**: Added `Github::Client` and `Github::ReferenceExtractor` to centralize GitHub fetch/pagination/cache logic and strict reference parsing rules
- **Deep PR crawl flag**: `DEEP_PR_CRAWL` can disable PR compare/linked PR deep crawling for faster dry runs and experiments
- **Run-level API cache + visibility**: In-memory cache avoids duplicate fetches for issue/PR meta, PR files, and comments; logs now show `[cache-hit]` with namespace/key and value summary

### Changed
- **Collection throughput and stability**: Added bounded parallel collection controls (`COLLECT_PARALLEL`, `MAX_COLLECT_THREADS`, `MAX_REPO_THREADS`), GitHub rate-limit exponential backoff (`429` and secondary-rate-limit `403`), and deterministic post-collection sorting to keep output order stable under concurrency.
- **GitHub release coverage for tag-first projects**: `github_release` collection now supports `auto` strategy (`releases -> tags` fallback) and optional changelog-file enrichment (`release_notes_files`) to reduce sparse summaries for repos that publish via tags/changelog files instead of GitHub Releases.
- **Issue-context rate-limit resilience**: `github_issue_collector` now limits context candidates per repo and caps token-mode comment fetch size; `Github::Client` pagination supports max-item short-circuiting to reduce `/issues/{number}/comments` pressure.
- **Architecture modularization**: Refactored shared logic into reusable modules/services across phases: `Utils::ItemTypeInferrer`, `Utils::TextTruncator`, `Utils::LogContext`, `Utils::ParallelExecutor`, `Github::PrCompareFormatter`, `Github::PrContextBuilder`, `Services::DigestPipeline`, `Services::CategoryCollector`, `Services::DigestFilter`, plus extracted `DigestLimits` and a thin `WebTechFeeder.run` entrypoint.
- **Logging and observability UX**: Introduced `Utils::LogFormatter`, ANSI/BBS startup and phase output, improved runtime/timing readability, reduced repeated CID prefixes, added colorized tags for compare/link-related logs, and added `VERBOSE_THREAD_LOGS` for thread-level tracing when needed.
- **AI processing behavior**: Increased per-item processor body truncation from 200 to 800 chars, retries up to 3 times for any category processing error before fallback, and reduced category pacing delay from 15s to 5s.
- **Reference parsing accuracy**: Tightened GitHub reference extraction to reduce false positives from non-GitHub tracker IDs, and added changelog-style bracket reference support (for example, `[#1234]`, `[PR #1234]`) to improve linked PR resolution quality.
- **Runtime defaults and date semantics**: CI now enables YJIT by default (`RUBY_YJIT_ENABLE=1`), local runs can opt in via `.env`, and `LOOKBACK_DAYS` now uses TPE full-day boundaries (`N days ago 00:00` to now).
- **DevOps source curation**: Adjusted PostgreSQL/Redis scope toward release and security relevance (added PostgreSQL server releases; removed overly detailed Planet PostgreSQL RSS and Redis from `github_issues`).
- **Documentation alignment**: Updated `README.md`, `.env.example`, and docs (`CONTRIBUTING`/`PLAN`/`GITHUB_ACTIONS`) to reflect deep PR crawl, parallel controls, lookback semantics, YJIT behavior, retries, and modularized architecture.
- **Email rendering strategy**: Digest template moved to table-first layout with client-aware dual rendering (Outlook-safe baseline + Gmail/Webmail visual enhancements), while preserving markdown-like code styling in summary blocks.

### Fixed
- **Nginx false references**: Avoid repeated 404 noise when non-GitHub `#number` tokens are mistakenly treated as GitHub issue/PR references
- **AI failure observability**: Retry and final-failure logs now include error class, reason, and short backtrace
- **YJIT local bootstrap robustness**: `bin/generate_digest` now re-execs with `--yjit` when `.env` sets `RUBY_YJIT_ENABLE=1`, and uses an absolute script path to avoid path resolution issues
- **Forwarded email clipping/truncation**: Removed container clipping risk and improved long-token wrapping so the last item and inline code content are less likely to appear visually cut off after forwarding.
- **Rate-limit backoff behavior**: Retry wait now honors `X-RateLimit-Reset`/`Retry-After` when available (with jitter and higher max wait) to reduce repeated 403 bursts.

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

[Unreleased]: https://github.com/william-eth/web_tech_feeder/compare/1.0.1...HEAD
[1.0.1]: https://github.com/william-eth/web_tech_feeder/compare/1.0.0...1.0.1
[1.0.0]: https://github.com/william-eth/web_tech_feeder/compare/0.1.5...1.0.0
[0.1.5]: https://github.com/william-eth/web_tech_feeder/compare/0.1.4...0.1.5
[0.1.4]: https://github.com/william-eth/web_tech_feeder/compare/0.1.3...0.1.4
[0.1.3]: https://github.com/william-eth/web_tech_feeder/compare/0.1.2...0.1.3
[0.1.2]: https://github.com/william-eth/web_tech_feeder/compare/0.1.1...0.1.2
[0.1.1]: https://github.com/william-eth/web_tech_feeder/compare/0.1.0...0.1.1
[0.1.0]: https://github.com/william-eth/web_tech_feeder/compare/a4d0ccd...0.1.0
