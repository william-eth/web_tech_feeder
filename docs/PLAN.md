# Design & Implementation Plan

Records key design decisions and implementation direction for collaboration.

Scope of this document:
- Focus on architecture decisions, trade-offs, and rationale
- Avoid repeating step-by-step setup/operations (covered by root `README.md`)
- Avoid contributor workflow details (covered by `CONTRIBUTING.md`)

---

## 1. Email: Gmail API OAuth vs SMTP

### Decision

Use **Gmail API + OAuth 2.0 Refresh Token** instead of SMTP + app password.

### Rationale

- No need to store Gmail password or App Password in env
- OAuth allows scoped permissions (e.g. `gmail.send` only)
- Refresh Token is long-lived; Access Token is refreshed automatically

### Implementation Notes

- Use `google-apis-gmail_v1` + `googleauth` for Gmail API
- Build RFC 2822 with `mail` gem, pass raw string to API (**do not** manually base64 encode; client handles it)
- Obtain Refresh Token via OAuth 2.0 Playground; must use **your own** Client ID/Secret

---

## 2. Digest Summary Format

### Decision

Each item has three blocks: **📌 Core point / 🔍 Technical details / 📊 Recommended actions** with block-specific depth (typically 2–6 sentences), and `📊` uses Action/Awareness modes based on urgency.

### Rationale

- Consistent structure for quick scanning
- Avoid one-liners; provide enough detail for readers to understand impact and next steps
- Prevent over-prescriptive output: only require commands/config patches when immediate change is necessary

### Implementation Notes

- **Action mode**: include at least one concrete action (command or code/config patch) plus one validation step (test/check/log)
- **Awareness mode**: avoid forced commands; state impact-check scope, trigger condition for future action, and monitoring focus
- When code is included in `📊`, use explicit fence language tags (`ruby`, `ts`, `js`, `shell`, `yaml`) for readability

### Content-Type Variations

| Type | Additional requirements |
|------|--------------------------|
| Release | List 2–3 items developers must watch for |
| PR/Issue | Include problem, debate, conclusion |
| Advisory | Describe vulnerability and upgrade version |
| API changes | Explicitly mark deprecated, sunset, input/output changes |

---

## 3. Framework Badge for "Other Updates"

### Decision

Show framework/package badge (e.g. Rails, Node.js) for each item in the "Other updates" subsection.

### Rationale

- PR, Issue, and RSS sources are varied; tagging by tech stack aids identification
- Release titles usually already include project name; no duplicate badge needed

### Implementation

- AI outputs `framework_or_package` field
- Template shows badge only when `subsection_title == "其他動態"` (Other updates)

---

## 4. DevOps GitHub Advisories

### Decision

Use a two-layer security source strategy for DevOps:

- `github_advisories` for **Go ecosystem** packages
- `github_repo_advisories` for repository-level advisories on C/server projects (e.g. Valkey, PostgreSQL, Redis, Nginx)

### Rationale

- Common DevOps tools (Kubernetes, OpenTofu, containerd, Docker CLI, Helm, Grafana, ArgoCD) are written in Go
- GitHub Advisory Database supports Go ecosystem filtering by module path
- Some infrastructure/server projects publish advisories at repository level and are not reliably covered by ecosystem package filters

### Packages

```yaml
ecosystem: go
packages:
  - github.com/containerd/containerd
  - github.com/opencontainers/runc
  - k8s.io/kubernetes
  - github.com/opentofu/opentofu
  - github.com/docker/cli
  - github.com/moby/moby
  - helm.sh/helm/v3
  - github.com/grafana/grafana
  - github.com/argoproj/argo-cd/v2
```

```yaml
github_repo_advisories:
  - owner: valkey-io
    repo: valkey
    name: Valkey
  - owner: postgres
    repo: postgres
    name: PostgreSQL
  - owner: redis
    repo: redis
    name: Redis
  - owner: nginx
    repo: nginx
    name: Nginx
```

---

## 5. Multiple Recipients (EMAIL_TO)

### Decision

`EMAIL_TO` supports comma or semicolon separated addresses.

### Implementation

- `parse_email_list`: split on `[,;]`, strip each, filter empty
- Pass array to Mail gem `to`

---

## 6. GitHub Actions

### Decision

- `GITHUB_TOKEN`: Prefer `GH_PAT_TOKEN`; fallback to `github.token` when unset
- `AI_PROVIDER`: Default `gemini`
- Do not create a secret named `GITHUB_TOKEN` (GitHub reserved)

---

## 7. Lookback Time Window (TPE Full-Day)

### Decision

`LOOKBACK_DAYS` uses full-day boundaries in TPE (UTC+8), not rolling hour windows.

### Rationale

- Digest ranges are easier to reason about when aligned to calendar-day boundaries
- Avoid timezone drift between local/dev/CI environments

### Implementation

- Cutoff is computed as: **N days ago at 00:00 in TPE**
- Effective range: `cutoff_time..Time.now`

---

## 8. Deep PR Crawl Toggle

### Decision

Add `DEEP_PR_CRAWL` to control expensive PR deep enrichment paths.

### Rationale

- Full PR compare + linked PR resolution is valuable but expensive during experiments
- Fast validation runs should be possible without changing source code

### Implementation

- `DEEP_PR_CRAWL=true` (default): full enrichment
- `DEEP_PR_CRAWL=false`: skip PR compare and linked-PR deep crawling

---

## 9. Run-Level API Cache

### Decision

Use run-level in-memory cache for GitHub enrichment endpoints.

### Rationale

- The same PR/Issue often appears across release, issue, and RSS enrichment paths
- Caching reduces duplicate API calls and lowers latency/rate-limit pressure

### Implementation

- Cache namespace/key model with thread-safe access
- Cache includes `nil` results (for example 404) to avoid repeated failed lookups
- Cache hits are logged for observability

---

## 10. AI Reliability and Retry Policy

### Decision

Retry AI processing up to 3 times per category for any processing error.

### Rationale

- Provider/network instability and malformed responses are often transient
- Per-category retries keep pipeline resilient without re-running data collection

### Implementation

- Retries apply to API errors, network errors, empty responses, and invalid JSON
- Exponential backoff: 30s, 60s, 120s
- Category-to-category pacing: 5 seconds
- After retries are exhausted, fallback summary is used for that category

---

## 11. Shared GitHub Abstractions (DRY Refactor)

### Decision

Consolidate duplicated GitHub logic into shared modules:

- `WebTechFeeder::Github::Client`
- `WebTechFeeder::Github::ReferenceExtractor`

### Rationale

- GitHub API calls and reference parsing were duplicated across collectors and enrichers
- Duplicate code increases drift risk (same rule implemented differently over time)
- Shared abstractions reduce maintenance cost and make behavior consistent

### Implementation

- `Github::Client` is responsible for:
  - Auth headers and token mode detection
  - Shared fetch methods for issue/PR meta, comments, and PR files
  - Full pagination flow for token mode
  - Run-level cache integration (including cached `nil`)
- `Github::ReferenceExtractor` is responsible for:
  - Strict GitHub reference extraction (`URL`, context keyword + `#number`, `GH-<number>`)
  - Excluding non-GitHub tracker patterns (for example `ticket #1234`)
- Collectors/enrichers now consume these shared modules instead of owning duplicated helper methods.

---

## 12. Runtime Observability UX (ANSI/BBS Logging)

### Decision

Add visually distinctive startup/phase logs while keeping structured machine-readable context.

### Rationale

- Long runs produce dense logs; key milestones should be immediately recognizable
- Better operator experience during dry-run validation and CI troubleshooting

### Implementation

- ANSI/BBS-style banners for `START`, `DONE`, `FAILED`, and `NO DATA`
- Highlighted multiline runtime config block (provider/model/toggles/token/yjit)
- Run timing footer with `started_at`, `finished_at`, `elapsed_seconds`, and status
- Keep `cid` for correlation across collectors, enrichers, and processor logs

---

## 13. Parallel Collection and Output Stability

### Decision

Add configurable parallel collection for source-level and repo-level fetching, with deterministic output ordering.

### Rationale

- Collection is I/O-bound (GitHub/RSS/Redmine HTTP calls), so parallelism can reduce wall-clock time
- Uncontrolled concurrency increases 403/429 risk; parallelism must be bounded and retry-aware
- Parallel execution can produce non-deterministic item order, which hurts digest consistency

### Implementation

- New toggles:
  - `COLLECT_PARALLEL=true|false`
  - `MAX_COLLECT_THREADS` (source-level workers)
  - `MAX_REPO_THREADS` (repo-level workers inside GitHub collectors)
- Token-aware defaults:
  - with token: `MAX_COLLECT_THREADS=4`, `MAX_REPO_THREADS=3`
  - without token: `MAX_COLLECT_THREADS=2`, `MAX_REPO_THREADS=2`
- GitHub client adds exponential backoff retry for rate-limit responses:
  - retry on `429` and rate-limit flavored `403` (including secondary rate limit)
  - backoff is exponential with capped wait time
- Final category item list applies stable sort after collection:
  - primary key: `published_at` desc
  - tie-breakers: title/source/url

---

## 14. Service-Oriented Pipeline Split (Phase 3)

### Decision

Split the previous monolithic orchestrator into dedicated service objects.

### Rationale

- Pipeline orchestration, collection orchestration, and digest shaping are separate concerns
- Smaller classes improve readability, testability, and change isolation
- Keeping `WebTechFeeder.run` as a thin entrypoint lowers coupling at startup boundaries

### Implementation

- `WebTechFeeder.run` now delegates to `Services::DigestPipeline`
- Collection flow moved to `Services::CategoryCollector`
- Post-AI filtering/splitting moved to `Services::DigestFilter`
- Shared limits extracted to `lib/digest_limits.rb`

---

## 15. Log Presentation Refinement (Phase 3.1)

### Decision

Extract pipeline log rendering into a reusable formatter and reduce repetitive run-id noise.

### Rationale

- Pipeline class should focus on workflow, not ANSI/banner formatting internals
- Repeating the same CID on every nearby line hurts readability
- Colored tags improve scan speed for compare/link/cache heavy logs

### Implementation

- Added `Utils::LogFormatter` for:
  - Startup/final banners, phase markers, runtime config, run timing
  - Dry-run preview highlight output
- Added `Utils::LogTagStyler` for colorized tags (for example `pr-files`, `linked-refs`, compare-related tags)
- Runtime/collection logs now avoid repeating CID on every adjacent line while keeping run-level context at key points

---

## 16. Security Advisory Fallback & Enrichment

### Decision

Treat security coverage as a layered pipeline, not a single AI-output dependency.

### Rationale

- AI summaries can occasionally miss explicit CVE/GHSA items
- Release/news entries can contain critical security fixes that still need dedicated advisory cards
- CVSS quality varies by upstream source; using multiple trusted feeds improves reliability

### Implementation

- **Processor guardrail (`BaseProcessor`)**:
  - Prioritize CVE/GHSA items before prompt truncation
  - If AI output lacks a qualified advisory item, inject one from high-signal raw items
  - Build advisory summaries with structured blocks (🛡️/⚔️/🔧)
  - Normalize advisory `importance` from raw CVSS metadata or parsed summary CVSS before downstream filtering/rendering
- **Filter safety net (`DigestFilter`)**:
  - If no advisory survives upstream, synthesize advisory entries from explicit CVE/GHSA items
  - Keep release/security/other splitting deterministic with dedicated caps and importance thresholds
- **CVSS enrichment (`Utils::CveEnricher`)**:
  - Primary source: NVD API 2.0
  - Fallback source: Amazon Linux Security Center (ALAS)
  - Preserve source attribution and reuse CVE descriptions when raw body content is template-like or low-signal
- **Renderer normalization (`TemplateRenderer`)**:
  - Enforce security block labels and CVSS/risk lines
  - Link CVE references to `cve.org`
  - Normalize markdown/bullet formatting for email-client consistency

---

## 17. Frontend React Ecosystem Revamp

### Decision

Restructure the frontend section around React ecosystem new knowledge from curated
blog/article sources, with GitHub releases as supplementary content.

### Rationale

- The original frontend section was release-heavy (Node.js, TypeScript, React, Next.js
  releases) with weekly newsletter RSS as supplementary. This provided version tracking
  but lacked practical insight for React application developers.
- Curated technical blogs (TkDodo, Josh W. Comeau, React Official) and Dev.to trending
  articles provide higher-signal content about modern patterns, performance, and DX.
- A dedicated summary format (pain point / core mechanism / practical takeaway) better
  serves developers who want actionable knowledge rather than version diffs.

### Implementation

- **Source layer**:
  - Primary: Dev.to API (`DevtoCollector`) + curated RSS feeds (marked `primary: true`)
  - Secondary: GitHub releases/issues (kept for version tracking + security coverage)
  - Evergreen keyword pools in `sources.yml` for soft relevance boosting
- **Processor layer** (`BaseProcessor`):
  - Keyword matching tags items as high-value via `metadata[:keyword_match]`
  - `prioritize_keyword_items` sorts primary/keyword items before truncation
  - `format_items` outputs `Priority: high-value` line for AI awareness
- **Prompt layer** (`category_digest.erb`):
  - Frontend-specific persona: senior frontend architect / tech curator
  - FORMAT C (🎯 痛點解析 / ⚙️ 核心機制 / 💡 實戰啟發) for issue/other items
  - Release items keep FORMAT A; advisory items keep FORMAT B
  - Item selection rule prioritizes 3-4 curated articles over routine GitHub items
- **Rendering layer**:
  - Frontend subsections: 本週精選 (primary) → 版本釋出 → 🔒 資安情報
  - `TemplateRenderer#summary_parts` recognizes all three icon sets via unified map

---

## Future Considerations

- [ ] Support more AI models or providers
- [x] Configurable digest filters (e.g. by keyword) — implemented via evergreen keywords for frontend
- [ ] Multi-language output
- [ ] Digest history archive or web preview
