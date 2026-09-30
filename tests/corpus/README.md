# Detection corpus

Fixture diffs with expected findings. This is the only thing in the repo that
measures whether the **review is any good**, as opposed to whether the plumbing
works.

Everything in `tests/bats/` and `tests/python/` tests the envelope: does the
JSON parse, does the gate fire, do comments dedupe. All of it would still pass
if the rubric were replaced with "report nothing". This corpus is the ratchet
that stops a rubric edit quietly reducing detection.

**It is not part of `bash tests/run.sh`.** Every case costs a real model call,
so it runs on demand, like `tests/bats/sandbox.bats`.

## Running it

```bash
export AI_REVIEW_TOOL=claude
export ANTHROPIC_API_KEY=sk-...
# ...or, if your CLI is already logged in and has no key in the environment:
#   export AI_REVIEW_CLI_NATIVE_AUTH=1     (public endpoint — docs/private-endpoints.md)
bash tests/corpus/run.sh                 # every case
bash tests/corpus/run.sh 01 04           # just these
bash tests/corpus/run.sh --profile base,cms-ars-5.1
```

You get a per-case table and a summary:

```
  01-hardcoded-aws-key        FOUND 1/1   extra 0
  02-sql-injection-fstring    FOUND 1/1   extra 1
  07-benign-refactor          CLEAN       extra 0   (expected clean)
  ...
  recall 6/7 expected findings   1 case(s) with unexpected findings
```

Run it before and after a rubric change. A drop in recall, or a jump in extras,
is the signal. Absolute numbers are less interesting than the delta — and one
run is a sample, not a measurement: re-run a case before concluding the rubric
caused a change.

## Case layout

```
tests/corpus/01-hardcoded-aws-key/
  case.md          what this exercises, and which rubric rule
  base/            files as they exist BEFORE the change (optional)
  head/            files as they exist AFTER  (required)
  expected.json    what the review must report
```

The runner builds a scratch git repo, commits `base/`, overlays `head/`,
commits that, and runs the engine with `--against` the first commit. No patch
files — a tree that is checked in is easier to read and cannot fail to apply.

### `expected.json`

```json
{
  "clean": false,
  "findings": [
    {
      "path": "src/config.py",
      "min_severity": "HIGH",
      "perspective": "security",
      "must_match": ["secret", "environment"]
    }
  ]
}
```

- `min_severity` — the finding must be at least this severe. Use the floor you
  would actually accept, not the severity you hope for; a corpus that fails on
  HIGH-vs-CRITICAL disagreement measures the model's calibration rather than
  its detection, and you will stop trusting the corpus.
- `must_match` — case-insensitive substrings, all of which must appear in the
  finding's title or description. Keep them to the *concept* ("secret",
  "parameterized"), not to phrasing the model has no reason to reuse.
- `perspective` — optional; `security` or `compliance`.
- `clean: true` — a **negative case**: any finding is a failure. Use it only
  where the fixture genuinely has nothing else to report.
- `forbidden` — expectations that must NOT be matched, using the same rules.
  Any match fails the case. This is the targeted negative, and usually the one
  you want: a realistic resource always gives a thorough reviewer *something*
  to say, so `clean: true` on one ends up measuring how complete the fixture is
  rather than how good the rubric is. Case 05 failed every run that way, on
  seven legitimate findings that had nothing to do with what it tests. Unmatched
  findings still show in the `extra` column, so noise stays visible without
  failing the case.

At least a quarter of the corpus should be negative cases of one kind or the
other. Precision is what determines whether teams keep the tool, and a corpus
of only positive cases rewards a rubric that reports everything.

```json
{
  "clean": false,
  "findings": [],
  "forbidden": [
    { "path": "infra/rds.tf", "min_severity": "LOW",
      "perspective": "compliance", "must_match": ["encrypt"] }
  ]
}
```

### Fixtures assert what they mean

Two traps, both found by running the corpus rather than reading it:

- **Case 01** asserted CRITICAL on a "live-looking" credential while using
  `AKIAIOSFODNN7EXAMPLE` — the pair AWS publishes in its own documentation. A
  run downgraded it to LOW with exactly the right reasoning, and the case
  measured whether the model recognizes AWS's example key rather than whether it
  catches hardcoded credentials. If a fixture needs a value to look real, it
  must not be one a careful reader can identify as a placeholder.
- **Case 05** used `clean: true` on a realistic RDS instance, so it failed on
  missing tags and single-AZ — true observations, unrelated to the encryption
  assertion it exists for.

A case that fails for reasons unrelated to what it tests is one people learn to
ignore, which costs more than the case was ever worth.

### Secret scanning will not stop you adding a case

The repo has **secret scanning and push protection both enabled**, and
`.github/secret_scanning.yml` excludes `tests/corpus/**` from alerts. Push
protection is a separate mechanism that `paths-ignore` does **not** cover, so
on paper a new case carrying a credential-shaped fixture should have its push
rejected.

Measured on 2026-09-30, it isn't. Pushing case 01's full AWS pair as a new
blob — into `tests/corpus/**` and, as a control, into `engines/**`, which is
deliberately *not* excluded — was accepted both times and raised no alert
either time.

The reason matters more than the result, because it is the thing that could
change. GitHub's AWS detector is provider-validated: AWS confirms whether a
detected credential is live, and a fixture cannot be. Pattern-only detection is
the `secret_scanning_non_provider_patterns` setting, which is part of the paid
GitHub Secret Protection tier and **cannot currently be enabled on this repo**
— the API accepts the request with HTTP 200 and silently leaves it `disabled`,
as it does for `secret_scanning_validity_checks`.

So the exclusions in `.github/secret_scanning.yml` are presently belt to a
brace nobody is wearing. Keep them: they cost nothing, they document intent,
and they are what stands between this corpus and a wall of alerts on the day
Secret Protection gets licensed. If a push of yours is ever rejected for a
fixture, that day has arrived — use the bypass flow GitHub offers in the
rejection message ("it's used in tests"), and say so in the PR.

## Getting to 20+ cases

In descending order of value:

**1. One case per rubric rule.** Walk `skills/base/code-security.md` and
`iac-compliance.md` and write a minimal diff for each numbered check. This is
the highest-value source because it tests *your* rubric rather than a generic
notion of vulnerability — and it immediately tells you which rules are
unreachable or unstated.

**2. Negative controls.** For each positive case, consider its already-mitigated
twin: the same shape with the fix present (parameterized query, encryption
already set, an account-level guard elsewhere in the diff). These catch the
failure mode adjudication exists for, and the adjudication rubric already names
several.

**3. Public vulnerable-by-design fixtures**, for realism you would not think to
write. [TerraGoat](https://github.com/bridgecrewio/terragoat) and
[CfnGoat](https://github.com/bridgecrewio/cfngoat) are purpose-built misconfigured
IaC; [OWASP WebGoat](https://github.com/WebGoat/WebGoat) and the
[NIST SARD Juliet](https://samate.nist.gov/SARD/) suites cover app-layer.
Check the licence before vendoring, and reduce each to a minimal diff — a whole
vulnerable app measures nothing useful.

**4. Inverted CVE fix commits.** A fix commit's parent is, by definition, a
vulnerable state. Reducing a real fix to a two-file diff gives you a case that
is known-exploitable rather than merely suspicious.

**5. Your own adopted repos.** Once this is running in real programs, the best
source is findings people confirmed or rejected — anonymized. That corpus
reflects what your programs actually write, which none of the above does.

Aim for breadth over depth first: one case per rubric area beats five on
secrets. The gaps that matter are the perspectives with no case at all.

## What this cannot tell you

- **Recall against real-world code.** Minimal fixtures are easier than a
  3,000-line PR. High recall here is necessary, not sufficient.
- **Whether severities are calibrated.** `min_severity` is a floor, so a rubric
  that reports everything as CRITICAL still passes. If you want calibration,
  assert exact severities in a subset and accept the flakiness.
- **Cross-model agreement.** Run the corpus under each `AI_REVIEW_TOOL` you
  support. Divergence there is worth knowing before you ship `gate: true`,
  because the gate's threshold is a severity the model assigns.
