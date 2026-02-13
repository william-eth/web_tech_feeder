# Digest Prompt Guidelines

Reference for contributors modifying `lib/prompts/category_digest.erb`.

## Summary Structure

Each item must have three blocks, separated by line breaks:

1. **📌 Core point** (2–4 sentences): What changed, the issue, release overview, impact scope
2. **🔍 Technical details** (2–4 sentences when relevant): How it works, breaking changes, migration impact; omit if trivial
3. **📊 Recommended actions** (2–3 sentences): Concrete next steps, version targets, testing tips

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

## Framework / Package Tagging

- **advisory / issue / other**: Must set `framework_or_package` (e.g. Rails, Node.js, Kubernetes, puma)
- **release**: Include when it aids clarity (e.g. multiple projects in same category)
- Template displays as badge in the "Other updates" subsection

## JSON Output

Each item must include: `title`, `summary`, `importance`, `item_type`, `framework_or_package`, `source_url`, `source_name`  
`item_type`: `release` | `advisory` | `issue` | `other`
