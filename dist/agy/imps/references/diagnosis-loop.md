# Diagnosis loop

Use this for bugs, regressions, flaky behavior, performance problems, and unexplained
gate failures. The loop exists to prevent a plausible theory from replacing evidence.

1. Establish one fast command that can detect the reported symptom. Run it and capture the
   red result before forming a theory. Prefer, in order: a focused test, CLI/HTTP invocation,
   browser assertion, captured-input replay, or a small throwaway harness.
2. Tighten the signal: assert the exact symptom, remove unrelated setup, and pin time,
   randomness, filesystem, and network behavior where possible. For a flake, raise the
   reproduction rate until failures are frequent enough to investigate.
3. Minimize the reproducer one input or dependency at a time. Keep only elements whose
   removal makes the symptom disappear.
4. Rank 3–5 falsifiable hypotheses. For each, state the observation that would distinguish
   it, then test one variable at a time. Prefer debugger inspection or targeted, uniquely
   tagged logs over broad logging.
5. Turn the minimized reproducer into a failing regression test at the public seam that
   exhibits the real bug. Apply the smallest fix, watch the test pass, then rerun the
   original command.
6. Remove temporary instrumentation and state the confirmed cause in the commit or handoff.

If no agent-runnable command can detect the exact symptom, stop and report what access or
redacted artifact is missing. Do not continue from an untested hypothesis.
