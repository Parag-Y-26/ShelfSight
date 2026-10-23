# Sanitization Report: ShelfSight

**Date:** 2026-10-23
**Auditor:** opensource-sanitizer v1.0.0
**Verdict:** PASS WITH WARNINGS

## Scope

Exact Git publication candidates: tracked files plus `git ls-files --others --exclude-standard`, excluding this generated report. Read 105 files: 88 UTF-8 text files and 17 binary image/font assets. Binary assets were read and byte-scanned. Ignored local credentials and runtime data were excluded from publication and their contents were not read.

## Summary

| Category | Status | Findings |
|----------|--------|----------|
| Secrets | PASS | 0 credential findings |
| PII | PASS | 0 findings |
| Internal References | PASS | 0 findings |
| Dangerous Files | PASS | 0 publish candidates |
| Config Completeness | WARN | 5 optional compatibility aliases not duplicated in examples |
| Git History | PASS | One initial root commit; all historical files and commit metadata scanned |
| Unreadable Files | PASS | 0 files |

## Critical Findings (Must Fix Before Release)

None. The TLS unit test now uses an RFC 5737 documentation address.

## Warnings (Review Before Release)

1. Configuration examples cover the optional Flutter keys. They omit compatibility aliases `DETECTOR_MODEL_PATH`, `DETECTOR_MODEL_SHA256`, `DETECTOR_MODEL_URL`, `GEMINI_API_KEY`, `GEMINI_MODEL`. Canonical server settings are all documented. Aliases are optional alternatives, not required secrets.

## .env.example Audit

- Variables in code but not examples: `DETECTOR_MODEL_PATH`, `DETECTOR_MODEL_SHA256`, `DETECTOR_MODEL_URL`, `GEMINI_API_KEY`, `GEMINI_MODEL`.
- Variables in examples but not code: none.
- Reviewed `server/.env.example` and `config/local.example.json`. The API-key regex consumed a newline after a blank variable and matched the next variable name; this is not an embedded credential. No Docker Compose file is present.

## Publication Exclusions

`git check-ignore` confirms that `server/.env`, `config/local.json`, `app/android/app/google-services.json`, and `runtime/pairing.json` are ignored. No ignored file is currently tracked. Dangerous local environments, TLS private material, logs, build output, and runtime data do not appear in the candidate manifest.

## Unreadable Files

**Unreadable count:** 0

Tally by type: none. No adjacent `Promptwars_PY.UNREADABLE_FILES.txt` was generated or required.

## Recommendation

Critical checks pass for the audited publication candidates. Canonical environment settings are complete; the five compatibility aliases are optional alternatives. The initial commit and staged publication content have been scanned. Include this updated report in the final commit before pushing. No source files were modified by the audit.

## Git History Audit

One root commit, `c2669ad`, with 105 historical files read. No secret, PII, internal-reference, or dangerous-file findings. Commit messages and author/committer metadata were also checked. The staged normalization changes and `.gitattributes` were scanned separately.

## Manifest Evidence

Both working files and normalized staged blobs were read. Sorted path plus file SHA-256, excluding this generated report:

- Working source manifest SHA-256: `92cd276c525453b4797205d10a8e487e94e811e964d45d4ba97e998678db4794`.
- Git index publication manifest SHA-256: `12811e9dab48b9ca1d6e58c4eb09f619fabb2a10247a8e68f3da4d385a7a5d60`.

The Git index hash identifies the normalized publication snapshot before adding this report update. The two manifests differ only where line-ending normalization changes file bytes.
