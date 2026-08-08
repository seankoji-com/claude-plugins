# discovery.md — required structure

Synthesise, do not transcribe. This document must stand entirely on its own: the next phase
reads it cold, with no access to the conversation that produced it. Dense prose, a few pages.
If a section would be empty, say so explicitly rather than dropping the heading — a missing
section reads as an oversight, an empty one reads as a decision.

## 1. The problem or decision
Plain English, a few sentences, no jargon. Someone outside the team should understand what is
being asked and why it matters before they hit the second heading.

## 2. Requirements and constraints
Everything that bounds the answer: budget, deadline, compatibility, compliance, people and
systems affected downstream. For implementation topics, name real paths and real commands —
`src/foo/bar.py`, `pytest tests/`, not "the parser" and "the test suite".

## 3. Tradeoffs discussed and how each was resolved
Not just the conclusion — the shape of the argument. A future reader asking "did we consider
the cost of X?" should find the answer here.

## 4. Alternatives considered and ruled out, with reasons
**Mandatory.** This is the highest-value section in the document and the one that most often
gets skipped. It answers "why did we choose this?" for anyone who arrives later, and it is the
guardrail that stops the execution phase from confidently re-proposing something already
rejected. Never delete a superseded entry — mark it superseded and keep the reasoning.

## 5. Explicit non-goals
What is out of scope, stated positively. Scope that arrived by association rather than need
belongs here, named, so it stays out.

## 6. Prior art
What the user has already read, tried, or ruled out, and why each failed to settle the
question. Includes the strongest existing case *against* the current lean.

## 7. Open questions
Anything still unresolved. An honest open question is worth more than a confident invention;
the phase that follows can plan around a known gap but not around a fabricated certainty.
