# QUALITY LOOP v2 - orchestration overview (firstmate follows this; the two role briefs are the workers' contracts)
# v2 rebuilt from a board review (IndyDevDan / Kun Chen / Austin Marchese) against the "Gauntlet Loop" idea.
# Trigger: captain says "quality loop on {SUBJECT}" (optional "to {TARGET}"; default 90 / "no blockers").

## The core fix (why v2 exists)
The v1 false-97 was NOT just self-scoring - ONE context wrote the rubric, built the thing, built the harness, AND graded it, and the harness FAKED the exact seam where the bug lived. So even an honest grader scored the wrong exam. v2 separates the roles and makes the evidence adversarial.

## Roles (two crewmates, not one)
- **BUILDER** (persistent worker) - `quality-loop-builder-brief.md`. Defines the bar (rubric + [machine]/[taste] partition + deterministic `checks/` + concrete reference artifacts + HOSTILE fixtures proven RED-then-GREEN through the real seam), then builds and captures evidence per pass. NEVER emits a score.
- **CRITIC** (fresh context, separate session, read-only, one dispatch per pass) - `quality-loop-critic-brief.md`. Sees ONLY the rubric + evidence + references + check/fixture results (never the builder's transcript/claims/scores). Verifies checks+fixtures green, grades [taste] COARSELY (blocker/weak/pass), names the single largest gap. Workhorse model mid-loop; strongest model on the final gate pass only.

## Firstmate arbitrates the loop
1. Dispatch BUILDER Phase 1. **Sanity-approve the rubric + references before Phase 2** (one-way door; for user-facing work, the captain approves). Do not let the builder amend the exam mid-build.
2. Per pass: builder builds+captures → dispatch a FRESH critic on the evidence → read `score.md` → relay ONLY the largest gap back to the builder (never the critic's chatter). Repeat.
3. **Stop at the FIRST of:** (a) zero blockers AND largest gap immaterial (critic's stated judgment) at/above {TARGET}; (b) plateau - critic delta negligible across 2 consecutive passes; (c) hard cap {MAX_PASSES} (default 3-4) → `needs-decision` to the captain to extend (that's a spend decision).
4. **Firstmate does the FINAL real-app re-score itself** - on the real build/app, by hand. The critic makes this cheap and rare-to-fail; it does NOT replace it. This is the one v1 rule kept unchanged.

## Refuse (from the Gauntlet Loop - cost theater at this scale)
- Amnesiac/fresh-context BUILDERS - no; only the CRITIC is fresh. The repo (`quality-evidence/` + gap lists) is the builder's memory.
- Per-component builder+critic pairs by default - no; one builder + one critic. Split only when the critic's gaps prove two genuinely independent fronts that don't share files; then each earns its own normal loop.
- Unbounded "loop until resources exhaust" - no; every loop has a cap + honest residue in the PR body.
- Precision-point arithmetic, dashboards, and a stale reusable-rubric library - no; coarse grades, `score.md` files, and a fresh rubric per task.
