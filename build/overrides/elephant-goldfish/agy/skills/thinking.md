<!-- REPLACE-SECTION: ## Why this command pins `model: opus` -->
## Why this skill carries no model field

On Claude Code this is the one command in the marketplace that pins `model: opus`, because
everything here is judgment work: the value is entirely in the quality of the questions and the
willingness to disagree with the user. The failure modes it guards against are specific —
accepting a first answer instead of pushing on it, asking questions whose answers the user
already had, softening a disagreement into "it depends", and running out of angles after two
rounds.

The generated skill carries `name` and `description` only. `docs/platform-matrix.md` records
no per-skill model field for this platform, so none is invented — choose the model at
invocation with `--model <name>` (matrix Item 8, which measured `agy -p` accepting it).

Nothing in the pipeline depends on that choice: the structural rules in Step 2 do most of the
work and help any model.

---
<!-- END-SECTION -->
