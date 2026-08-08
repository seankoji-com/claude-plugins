<!-- REPLACE-SECTION: ## Why this command pins `model: opus` -->
## Why this command carries no model field

On Claude Code this is the one command in the marketplace that pins `model: opus`, because
everything here is judgment work: the value is entirely in the quality of the questions and the
willingness to disagree with the user. The failure modes it guards against are specific —
accepting a first answer instead of pushing on it, asking questions whose answers the user
already had, softening a disagreement into "it depends", and running out of angles after two
rounds.

The generated copy carries no model frontmatter at all. Item 3 of `docs/platform-matrix.md`
measured that the Claude Code convention for a per-command model field is not honored here; it
did not rule out a differently-named field, so emitting none is a deliberate safe default
rather than a settled platform fact. Choose the model at invocation instead — pass
`-m <provider/model>` when you want a capable one for this command, otherwise it inherits the
session default.

Nothing in the pipeline depends on that choice: the structural rules in Step 2 do most of the
work and help any model.

---
<!-- END-SECTION -->
