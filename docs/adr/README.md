# Architecture Decision Records

A record of decisions that were hard to make, with the alternatives that were
rejected and why. An ADR is **not** a description of how something currently
works — for that, read the doc for the surface (`docs/architecture.md`,
`docs/security.md`, and the rest). An ADR is why it is that way.

## Convention

Format borrowed from [`navapbc/rebar`](https://github.com/navapbc/rebar), which
has the most established ADR practice in the org: `NNNN-kebab-slug.md`, a
`# ADR NNNN: <title>` heading, a `**Status:**` line, then Context / Decision /
Rejected alternatives / Consequences.

Deliberately **not** borrowed: rebar's collision-proof numbering machinery
(`.numbers/` marker files, a CI bijection check, a generated index). That is
right for 118 records and absurd for one. Numbering here is manual; check this
file for the next free number. Revisit if this list gets long enough to make
that a real risk.

`**Status:**` is one of:

| | |
|---|---|
| `Proposed` | Decided in principle, not implemented. A normal state, not a draft banner. |
| `Accepted` | Implemented and in force. |
| `Superseded by NNNN` | Replaced. The record stays — a reversed decision is still a decision someone needs the reasoning for. |

Implementation detail inside an ADR is indicative and will drift. The record is
the decision.

## Records

- [0001 — Distribute the codebase audit via Homebrew](0001-distribute-the-audit-via-homebrew.md) · **Proposed**

## Decisions this repo has already made and not yet recorded

The directory starts with one entry, but it is not the only thing that belongs
here. These are load-bearing, were argued out at the time, and currently survive
only in commit messages and doc prose — which is to say they survive until
someone changes them without knowing why they were that way:

- A commit SHA is the only acceptable pin; a tag is a mutable pointer.
- There is no moving `vX` alias, and that is deliberate.
- The AI phase holds no SCM token; posting is a separate phase.
- `AI_REVIEW_PROFILE` composes additively — base is a floor, later sources are
  appended and win conflicts. There is no override or fallback model.
- Adjudication defaults to `off`.
- The Copilot instruction sync tracks `main` rather than a SHA, because the PR
  is the gate.
- The gate floor is `HIGH` and is not configurable.

Writing these up is worth doing when someone next touches the area, rather than
as a batch.
