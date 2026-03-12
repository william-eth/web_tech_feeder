# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Security intelligence sub-section (🔒 資安情報)**: Added dedicated security block per category (Frontend/Backend/DevOps), displayed alongside "版本釋出" and "其他動態", with empty-state fallback.
- **Advisory summary format (🛡️/⚔️/🔧)**: Added security-only three-block summary structure and renderer-side label normalization for advisory cards.
- **Advisory metadata pipeline**: `Item` now supports `metadata`; GitHub advisory collectors pass CVE/CVSS/severity/version-range metadata into AI prompt input.
- **Security caps and thresholds**: Added `MAX_SECURITY_PER_CATEGORY` and `SECURITY_MIN_IMPORTANCE` in `DigestLimits`.
- **CVSS enrichment (`Utils::CveEnricher`)**: Fallback advisories fetch real CVSS scores from the NVD API 2.0, with Amazon Linux Security Center (ALAS) as a secondary source when NVD has no data. Both sources also extract CVE descriptions for use when raw body content is low-quality. Run-level cache, timeout, and retry; ALAS results are annotated with source labels.

### Fixed
- **Security fallback reliability**: Processor now prioritizes CVE/GHSA items before AI truncation, and avoids dropping advisory entries during URL dedup. Fallback candidate selection now strongly prefers items carrying explicit CVE/GHSA IDs over items with only keyword-level signals, preventing weak candidates from being chosen and subsequently rejected by the filter.
- **Missing advisory when CVE appears in release/news**: Added filter-level advisory injection fallback from explicit CVE/GHSA items when upstream output contains no advisory.
- **Advisory items dropped by filtering**: Advisory items now bypass the general importance filter and use security-specific thresholds; low-importance AI advisories no longer block fallback advisory injection.
- **Release duplication**: Added release deduplication by normalized project+version key with source-url fallback when version is unavailable.
- **Framework badge correctness for advisories**: Expanded fallback framework inference (Docker/Moby, Go, PostgreSQL, Redis/Valkey, Grafana, Amazon EKS AMI, React, Next.js).
- **Rendered summary corruption**: Fixed GitHub issue-ref linkification regex so CSS color fragments (e.g. `color:#0369a1`) are not transformed into issue links.
- **Advisory card quality guardrails**: Filter now drops advisory items without explicit security material and avoids generic low-signal security cards.
- **Advisory CVSS always "無法確認"**: Fallback advisories now display real CVSS scores from NVD/ALAS when available, falling back to AI estimation only when both sources do not provide scores.
- **Redundant/low-signal vulnerability description**: `extract_security_description` now extracts structured section headers and substantive explanations instead of bare CVE reference sentences; duplicate CVE bullets are suppressed, and GitHub template field labels/bodies are skipped.

### Changed
- **Security rule maintainability**: Extracted shared CVE/GHSA/security-signal helpers to `Utils::SecuritySignal` and reused them in processor/filter paths to reduce rule drift.
- **Prompt and routing policy**: Prompt now requires separate advisory entries for explicit CVE/GHSA fixes; release summaries stay focused on non-security highlights.
- **Security section rendering behavior**: Security summaries enforce CVSS/risk lines and convert fallback 📌/🔍/📊 structures to 🛡️/⚔️/🔧 for consistent presentation.
- **Linking and formatting**: CVE references now link to `cve.org`; markdown bold (`**x**` and malformed `*x**`) and grouped bullet indentation/spacing are normalized in renderer output.
- **Release/readability normalization**: Version-like tags (e.g. `v3_4_9`) are normalized for display (`v3.4.9`) in titles and summary text.
- **DevOps security source scope**: Removed Terraform/HashiCorp bulletin inputs from active collection while retaining OpenTofu sources.
- **Internal refactor (no behavior change)**: Simplified repeated constants/helpers in `BaseProcessor` and `Utils::CveEnricher`, and unified `DigestFilter` security-signal checks through `Utils::SecuritySignal`.

### Documentation
- Updated `docs/PLAN.md` with the security advisory fallback/enrichment architecture (AI output guardrail, filter safety net, NVD+ALAS enrichment path, and rendering normalization responsibilities).

## [1.1.0] - 2026-03-04

### Added
- **Repository-level security advisories**: New `github_repo_advisories` source and `GithubRepoAdvisoryCollector` for projects not covered by ecosystem advisories. Frontend: React, Next.js. Backend: Ruby on Rails. DevOps: Valkey, PostgreSQL, Redis, Nginx.
- **Valkey server source**: Added Valkey (server) to DevOps `github_releases` and `github_repo_advisories`.
- **DRY_RUN_FROM_CACHE**: Skip collection and load from `tmp/collected_raw_data.json` for fast prompt/template iteration without re-fetching.
- **Project version in email footer**: `PROJECT_VERSION` env (e.g. from CI tag) and AI-generated disclaimer line in digest footer.
- **OpenAI processor 429/5xx retry**: Short backoff retries for transient `429`, `500`, `502`, `503`, `504` and network errors before propagating failure.
- **Fatal API error early-abort**: `401`/`403`/`404` responses (`FatalApiError`) immediately stop AI processing for all remaining categories and fall back, avoiding wasted retries on permanent errors such as invalid credentials or non-existent models.
- **Code block syntax highlighting**: Lightweight tokenizer for Ruby/TS/JS/Shell/YAML with identifier handling (fixes `stdin` mis-colored as keyword).
- **Inline code IDE font stack**: `SF Mono`, `Menlo`, `Consolas` for better readability.
- **List bullet normalization**: Markdown `-` / `*` converted to `•` in summary content.
- **GitHub Issue linkification**: `#12345` and `(#12345)` in summary content become clickable links when `source_url` is a GitHub repo.
- **release_notes_path_template**: Dynamic changelog path for `github_releases` (e.g. `CHANGELOG/CHANGELOG-%{major}.%{minor}.md`); Kubernetes now enriches releases from per-minor changelog files.

### Changed
- **Summary section styling**: Stronger label styling (bold, border-bottom) to separate 核心重點/技術細節/建議動作 from body text.
- **DevOps Go advisories**: Extended packages to include OpenTofu, Docker Engine, Helm, Grafana, ArgoCD.
- **Prompt readability**: Enforce bullet lists, block-specific depth, avoid "見 source_url" and awkward prefixes like "現在要做"/"若你維護".
- **Prompt examples**: Rewritten to bullet-only format; alpha/rc releases use awareness-only guidance.
- **Prompt technical-detail grouping**: `🔍 技術細節` now enforces grouped output (first `變更點`, then `⚠ 影響`) with child bullets, replacing alternating change/impact narration and bracket-style labels.
- **Email rendering for grouped bullets**: Preserves nested indentation (`  •` via `&nbsp;`) and emphasizes group labels (`變更點：`, `⚠ 影響：`) with bold styling; tightened vertical spacing between labels and child bullets; collapsed extra blank lines after group labels.
- **API error reporting**: Error messages now extracted from JSON response body (`error.message`) instead of truncated raw text, providing full diagnostic detail on failure.

### Fixed
- **HTML entity breakage in linkify**: Excluded `&#39;` (apostrophe) from GitHub ref regex so `require('yargs')` no longer becomes `require(&<a>#39</a>;)`.
- **Truncation mid-issue-ref**: `truncate_text` no longer cuts `(#12345)` or `#12345` in the middle.
- **Grouped-label rendering corruption**: Reordered linkification and style-injection passes so GitHub `#123` regex no longer corrupts inline CSS color codes in `變更點/影響` labels.

### Removed
- **Legacy `/completions` fallback**: Removed unused text-completions endpoint fallback from OpenAI processor. All modern providers use `/chat/completions` exclusively; the dead path only caused confusing retry noise on unsupported models.

### Documentation
- **sources.yml**: Inline comments for `github_repo_advisories` (when to use, keep list small).
- **README / CONTRIBUTING / PLAN**: Documented `github_repo_advisories`, `DRY_RUN_FROM_CACHE`, `release_notes_path_template`, updated Security source descriptions, and DevOps two-layer advisory strategy.

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

[Unreleased]: https://github.com/william-eth/web_tech_feeder/compare/1.1.0...HEAD
[1.1.0]: https://github.com/william-eth/web_tech_feeder/compare/1.0.1...1.1.0
[1.0.1]: https://github.com/william-eth/web_tech_feeder/compare/1.0.0...1.0.1
[1.0.0]: https://github.com/william-eth/web_tech_feeder/compare/0.1.5...1.0.0
[0.1.5]: https://github.com/william-eth/web_tech_feeder/compare/0.1.4...0.1.5
[0.1.4]: https://github.com/william-eth/web_tech_feeder/compare/0.1.3...0.1.4
[0.1.3]: https://github.com/william-eth/web_tech_feeder/compare/0.1.2...0.1.3
[0.1.2]: https://github.com/william-eth/web_tech_feeder/compare/0.1.1...0.1.2
[0.1.1]: https://github.com/william-eth/web_tech_feeder/compare/0.1.0...0.1.1
[0.1.0]: https://github.com/william-eth/web_tech_feeder/compare/a4d0ccd...0.1.0
