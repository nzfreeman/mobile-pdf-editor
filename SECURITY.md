# Security Policy

## Supported versions

Security fixes are applied to the latest code on the `main` branch. Tagged releases may receive fixes when practical.

## Reporting a vulnerability

Please do not open a public issue for vulnerabilities, exposed credentials, authentication problems, or privacy concerns.

Use GitHub's private vulnerability reporting feature for this repository when available. Include:

- A clear description of the issue
- Reproduction steps or a minimal proof of concept
- Affected platforms and versions
- Potential impact
- Any suggested remediation

Please avoid accessing, modifying, or sharing data that does not belong to you. Do not include real personal PDFs, OAuth tokens, signing keys, or account credentials in a report.

The maintainer will review reports in good faith and coordinate disclosure after a fix is available.

## Secrets

If you discover a committed secret, revoke or rotate it immediately. Removing the file from the latest commit is not sufficient because it may remain in Git history.
