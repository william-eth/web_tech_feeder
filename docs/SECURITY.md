# Security Policy

## Reporting a Vulnerability

If you discover a security concern (e.g. code vulnerability, dependency issue), please report via:

1. **GitHub Security Advisories** (preferred): Repo **Security** tab → **Report a vulnerability** for private disclosure.
2. **Issue**: For non-sensitive issues, open a regular Issue and tag with `security`.

### Expected Response

- We aim to acknowledge reports within **7 business days**.
- Fix timeline depends on severity and implementation complexity.

### Scope

This project is a tech digest automation tool. It does not store user passwords; Gmail is used via OAuth 2.0 Refresh Token, and sensitive credentials are managed locally or in GitHub Secrets by the user. We welcome reports related to OAuth flow, API usage, or dependency vulnerabilities.
