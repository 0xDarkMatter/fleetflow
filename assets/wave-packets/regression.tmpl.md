# Regression lane — run `%%RUN%%`, wave `regression`

You write tests. You do not fix production code — if you find you need to,
that's a signal the fix wasn't actually complete; report it in your reply
rather than patching it yourself.

## Context

%%REPO_HINT%%

You are auditing the tree as of commit %%BASE_SHA%%.

## Findings to cover

Each entry below is a ledger finding whose fix has already landed. Your job
is to give it a regression test:

```json
%%FINDINGS_JSON%%
```

## Method

For each finding in the list above, write ONE test that:

- **Fails against the pre-fix behavior** — if you check it out against the
  commit before the fix (or simply reason about what the old code did),
  the test would have caught this exact defect.
- **Passes against the current tree** — run it now and confirm it's green.
- **Is named for the adversary, not the ticket** — a test named for the
  failure mode it blocks (e.g. `rejects-negative-quantity.test.ts`,
  `double-charge-on-retry.test.ts`), never a generic name like
  `finding-42.test.ts` or `bugfix.test.ts`. The name should tell the next
  person what evil this test exists to catch.
- Lives alongside the code it tests, following the target repo's existing
  test layout and framework — don't introduce a new test runner or
  directory convention to cover one finding.

If a finding's fix turns out to be incomplete or wrong while you're writing
its test (the test can't be made to pass without a code change beyond
tests), do not silently fix it — report that in your reply so it goes back
through triage instead of being quietly patched by the wrong lane.

## Severity rubric

%%SEVERITY_RUBRIC%%

## No silent caps

If you could not write a test for every finding in the list (e.g. one
requires infrastructure this repo doesn't have), say so explicitly in your
reply rather than silently skipping it.

## FINAL REPLY

Return a JSON array, one entry per finding you covered, then the
TESTS/FILES_CHANGED lines. An empty array `[]` is valid only if the
findings list above was empty.

Each array entry has this shape:

```json
{"fp": "<the finding's fp from the input above>",
 "test_file": "repo-relative/path/to/new-or-updated-test-file",
 "covered": true,
 "notes": "what the test proves, or why it couldn't be written"}
```

After the array, on their own lines:

```
TESTS: <passed>/<failed>
FILES_CHANGED: <n>
```
