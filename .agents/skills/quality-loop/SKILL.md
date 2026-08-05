---
name: quality-loop
description: >-
  Run an adversarial build-and-grade loop that drives a subject to a quality bar.
  Use when the captain invokes /quality-loop or says "quality loop on {subject}" (optionally "to {target}"), e.g. "/quality-loop the fade chat UI", "quality loop on the onboarding flow to 90".
  It dispatches one persistent builder and a fresh read-only critic per pass, keeps scoring off the builder, and stops on zero-blockers, plateau, or a pass cap before firstmate does the final real-app re-score by hand.
user-invocable: true
metadata:
  internal: true
---

# quality-loop

Firstmate's orchestration contract for a quality loop.
When the captain invokes `/quality-loop <subject> [to <target>]`, firstmate arbitrates an adversarial loop between two crewmates and does the final real-app re-score itself.
This skill is that arbitration contract; the three template files in this skill directory are the fill-in worker briefs it dispatches.
It exists because a v1 loop returned a false 97: one context wrote the rubric, built the thing, built the harness, and graded it, and the harness faked the exact seam where the bug lived, so even an honest grader scored the wrong exam.
v2 separates the roles and makes the evidence adversarial.

## Invocation

`/quality-loop <subject> [to <target>]`, or the captain saying "quality loop on {subject}".
`<subject>` is the thing to drive up in quality (a UI surface, a flow, a component, an output).
`to <target>` is optional; default target is "no blockers" (roughly 90).
Default hard pass cap is 3-4 passes.
Resolve the concrete project for the subject the same way any task intake does, and run the loop through crewmates - firstmate never builds or grades a project itself.

## The two roles (two crewmates, never one)

- **Builder** - one persistent worker, briefed from [`quality-loop-builder-brief.md`](quality-loop-builder-brief.md).
  It defines the bar, then builds and captures evidence per pass.
  It never emits a score; the repo (`quality-evidence/` plus the gap lists firstmate relays) is its memory.
- **Critic** - a fresh context in a separate session, read-only, dispatched once per pass, briefed from [`quality-loop-critic-brief.md`](quality-loop-critic-brief.md).
  It sees only the frozen rubric, the reference artifacts, and the pass evidence plus check results - never the builder's transcript, diff, claims, or prior scores.
  It verifies the checks and hostile fixtures are green, grades each taste dimension coarsely (blocker / weak / pass), and names the single largest gap.
  Use a workhorse model for mid-loop passes and the strongest model on the final gate pass only.

## What the builder must produce in Phase 1 (before any product code)

This is a one-way door; the builder commits all of it, then stops for firstmate approval before building.

- A weighted rubric, heaviest weight on the worst current problem.
- Every rubric line partitioned into **[machine]** (deterministic-checkable) or **[taste]** (needs judgment); if fewer than about half the points are [machine], the rubric is under-specified.
- A deterministic check script per [machine] line under `checks/` - grep, DOM-scan, or test, zero tokens, same result every run.
- 2-3 concrete real reference artifacts (real screenshots of the named-best products, or the project's own best prior state) committed next to the rubric; taste is judged by blind A/B against these, not against prose.
- A hostile fixture per known defect, through the real code path, mocking only below the lowest seam the defect crosses (name that seam), each proven RED before the fix with that red-run evidence committed.
  A harness never seen red is a rubber stamp, not a measuring instrument.
  Reuse a committed harness for the surface when one exists; a new harness is a reviewed deliverable.

## How firstmate arbitrates the loop

1. Dispatch the builder for Phase 1.
   Sanity-approve the rubric and references before Phase 2; for user-facing work the captain approves.
   Do not let the builder amend the exam mid-build.
2. Per pass: the builder builds and captures evidence to `quality-evidence/pass-N/`, then firstmate dispatches a fresh critic on that evidence, reads `score.md`, and relays only the largest gap back to the builder - never the critic's chatter or numbers.
   Repeat.
3. Stop at the first of:
   - zero blockers and the largest gap immaterial at or above the target (the critic's stated judgment);
   - plateau - the critic's delta is negligible across two consecutive passes;
   - the hard pass cap - then raise a `needs-decision` to the captain to extend, because that is a spend decision.
4. Firstmate does the final real-app re-score itself, on the real build or app, by hand.
   The critic makes this cheap and rare-to-fail; it does not replace it.
   This is the one v1 rule kept unchanged.

The orchestration overview in [`quality-loop-brief.md`](quality-loop-brief.md) is the same contract in brief form for reference.

## Refuse (cost theater at this scale)

- Amnesiac or fresh-context builders - only the critic is fresh; the builder is persistent and remembers through the repo.
- Per-component builder-and-critic pairs by default - one builder and one critic; split only when the critic's gaps prove two genuinely independent fronts that share no files, and then each earns its own normal loop.
- Unbounded "loop until resources exhaust" - every loop has a cap and honest residue in the PR body.
- Precision-point arithmetic, dashboards, and a stale reusable-rubric library - coarse grades, `score.md` files, and a fresh rubric per task.

## Boundaries

The loop runs entirely through crewmates and the normal task lifecycle; all existing firstmate safety boundaries hold.
The builder ships its result through the project's selected delivery path like any other task, and the honest residue (remaining gaps, passes spent, target met or not) goes in the PR body.
