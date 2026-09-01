# Cross-lineage code review brief

Review the merged diff against `GOAL.md` and the supplied repository standards. This is a
code review, not a plan review. The reviewer must be OpenCode running the pinned
`litellm/deepseek-v4-flash` model; never substitute or supplement it with Head Imp or
another same-lineage subagent.

Check three things:

1. Architecture: identify concrete coupling, duplication, unsafe lifecycle boundaries, or
   contract drift introduced by the changed files.
2. Correctness: name the input, state transition, race, or failure mode that breaks the
   implementation. Do not report a bug without a reproducible breaking scenario.
3. Contract fit: compare the complete changed files with `GOAL.md` and repository rules.
   Report missing requirements, partial implementations, and unauthorized scope.

Skip preferences already enforced by deterministic tooling. Every blocker or major finding
must cite a changed path and line, describe the breaking scenario, and propose a concrete
fix. Do not manufacture findings when the diff is sound.
