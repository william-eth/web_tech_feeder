# Digest Prompt Guidelines

Reference for contributors modifying `lib/prompts/category_digest.erb`.

## Summary Structure

Each item must have three blocks, separated by line breaks. Within each block, use **double newline (blank line)** to separate paragraphs. Use bullet points (• or -) when listing 3+ items.

Readability rules: short sentences (~25 words), one idea per sentence; avoid jargon stacking; lead with the key point.

1. **📌 Core point** (2–4 sentences): What changed, the issue, release overview, impact scope
2. **🔍 Technical details** (3–5 sentences when relevant): Exact change/problem, trigger scenario, concrete compatibility impact; omit if trivial
   - Group by meaning, not alternating narration:
     - Label line: `變更點：` + 2–3 indented child bullets (`  • A`, `  • B`)
     - Label line: `⚠ 影響：` + 1–2 indented child bullets (`  • C`, `  • D`)
   - Keep all change children contiguous, then all impact children contiguous
   - Avoid bracket labels like `[變更點]` / `[影響]`
3. **📊 Recommended actions** (3–6 sentences): Actionability depends on mode:
   - **Action mode** (change needed now): include at least one concrete action (command or code/config patch) and one validation step
   - **Awareness mode** (no immediate change needed): do not force commands; include impact check scope, trigger condition for action, and what to monitor next

When code patches are needed, include a minimal copy-paste snippet and prefer explicit fence language tags (`ruby`, `ts`, `js`, `shell`, `yaml`).

### Non-Official Releases (alpha, rc, beta)

Use Awareness mode only. Do not recommend adoption, production deployment, or upgrade. Focus on what changed and what to monitor. Never suggest "upgrade to vX.Y.Z-alpha".

### Code Snippet Rules

Include code blocks only when actionable (config, migration command, `bundle update`, etc.). Do not include `curl`/`wget` commands that fetch changelog; people read changelogs in the browser. Prefer direct links to the web changelog.

## Content-Type Requirements

### Release

- List **2–3 items** developers should watch for
- Cover breaking changes, migration-required features, config changes
- Examples: `find_each` behavior change, `deliver_later` queue name, deprecation output

### PR / Issue / Redmine / Forum

- **(1)** Problem or proposal raised
- **(2)** Points of debate or controversy in comments
- **(3)** Final conclusion or decision
- Summarize the full discussion arc, not just the opening post

### Advisory

- Vulnerability type and impact
- Trigger conditions and exploitation
- Recommended upgrade version or mitigation

### API / Function / Method Changes

- **Always highlight** input/output signature changes, deprecated APIs, sunset notices
- Include specific function/method names when relevant

## Category-Specific Rules

### Backend (後端技術動態)

- **Ruby-centric**: Prioritize Ruby, Rails, and Ruby gems
- **Go**: Include only (1) major/significant items (major version release, breaking change, important new feature) or (2) security-related (advisory, CVE)
- Skip: minor Go patch releases, routine Go blog posts, trivial Go issues

## Framework / Package Tagging

- **advisory / issue / other**: Must set `framework_or_package` (e.g. Rails, Node.js, Kubernetes, puma)
- **release**: Include when it aids clarity (e.g. multiple projects in same category)
- Template displays as badge in the "Other updates" subsection

## JSON Output

Each item must include: `title`, `summary`, `importance`, `item_type`, `framework_or_package`, `source_url`, `source_name`  
`item_type`: `release` | `advisory` | `issue` | `other`
