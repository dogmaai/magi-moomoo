# Agent instructions

## North-star specification: magi-knowledge OKF

All MAGI tasks in this repository MUST treat the OKF bundle in
[dogmaai/magi-knowledge](https://github.com/dogmaai/magi-knowledge) as the
single authoritative specification (Source of Truth). This rule applies at
every stage: task start, design, implementation, review, and completion
confirmation — for investigation, design, implementation, review, fixes,
completion checks, and Issue/PR authoring.

Canonical rule (Japanese, authoritative wording):

> MAGI関連の全タスクは、作業開始・設計・実装後・レビュー・完了確認の各段階で、対象リポジトリがpinしている dogmaai/magi-knowledge のOKFを参照する。報告には参照commit SHAとファイルパスを記載する。仕様とコードの矛盾は黙って解消せず、Junへ判断を求める。

### Canonical precedence

1. The OKF v0.2 bundle in `dogmaai/magi-knowledge`.
2. The magi-knowledge revision pinned by this repository. **This repository
   does not currently pin a revision** — until a `vendor/magi-knowledge`
   submodule pin is added (as in `magi-core`), reference the bundle's `main`
   branch and record the exact commit SHA used in every report.
3. Source code and running configuration (actual current behaviour).
4. Issues, PRs, conversations and prior handoff material.

`dogmaai/magi-stg` is archived and MUST NOT be referenced.

### Required checks at task start

1. Read this file, then record the magi-knowledge commit SHA being used.
2. In that revision, review: `index.md`, `AGENTS.md`,
   `COLLABORATION.md`, `system/constitution/`, `system/guards/`,
   `system/plm-units/`, `system/echidna-tables/`, `system/services/`, and the
   relevant `_lilith_safe/` boundaries.
3. Check each document's frontmatter: `status`, `verified.by`, `stale_after`.
   Never use `deprecated` docs. Treat `draft` or AI-generated-but-unverified
   content as a hypothesis, not confirmed specification.
4. If canonical documents are unreachable or contradict each other, report
   to Jun instead of guessing.

Re-check against the OKF before finalising a design, after code changes,
after tests, before opening a PR, after addressing review feedback, and
before the final completion report.

### Required report fields

Every start report, design proposal, PR description, review and completion
report must state:

- the magi-knowledge commit SHA referenced;
- the OKF file paths referenced;
- the relevant specs' `status` and `verified.by`;
- whether specification and code agree;
- contradictions, unverified items and hypotheses;
- affected units, guards, tables and data boundaries;
- verification commands run and their results;
- whether independent review is required.

"Checked the OKF" alone is not sufficient — name the revision and paths.

### Boundaries — never change without consulting the OKF and Jun

- trade guards, order execution, trading modes, risk configuration;
- the Constitution; the LILITH training-data boundary (`_lilith_safe/`);
- Deep Research Section 5 ("Jun Review Only") strip processing;
- BigQuery tables and regions;
- production deploys, IAM, Cloud Scheduler and other GCP infrastructure.

Changes to guards, order execution, trading mode, risk settings or the
LILITH boundary require review by someone other than the implementer.
Production deploys and GCP infrastructure changes are Jun's to approve and
execute — agents must not run them.
