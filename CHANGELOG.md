# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-02-14

### Added

- DevOps GitHub Advisories: Go ecosystem (containerd, runc, Kubernetes, Terraform, Docker CLI)
- Framework/package badge for "其他動態" items to clarify which framework/language/package each item relates to

### Changed

- **Prompt**: More detailed summary structure (2-4 sentences per block for 核心重點 / 技術細節 / 建議動作)
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

[Unreleased]: https://github.com/william-eth/web_tech_feeder/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/william-eth/web_tech_feeder/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/william-eth/web_tech_feeder/compare/a4d0ccd...v0.1.0
