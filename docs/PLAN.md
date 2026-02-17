# Design & Implementation Plan

Records key design decisions and implementation direction for collaboration.

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

Each item has three blocks: **📌 Core point / 🔍 Technical details / 📊 Recommended actions**, 2–4 sentences per block.

### Rationale

- Consistent structure for quick scanning
- Avoid one-liners; provide enough detail for readers to understand impact and next steps

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

Add `github_advisories` to DevOps section using **Go ecosystem**.

### Rationale

- Common DevOps tools (Kubernetes, Terraform, containerd, Docker CLI) are written in Go
- GitHub Advisory Database supports Go; filter by Go module path

### Packages

```yaml
ecosystem: go
packages: [github.com/containerd/containerd, github.com/opencontainers/runc, k8s.io/kubernetes, github.com/hashicorp/terraform, github.com/docker/cli]
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

## Future Considerations

- [ ] Support more AI models or providers
- [ ] Configurable digest filters (e.g. by keyword)
- [ ] Multi-language output
- [ ] Digest history archive or web preview
