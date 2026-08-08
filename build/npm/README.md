# claude-plugins-opencode

OpenCode channel for [seankoji/claude-plugins](https://github.com/seankoji/claude-plugins).
This package's tree is generated: `build/generate.py` mirrors this `build/npm/` source
verbatim into `dist/opencode/`, alongside the generated `commands/*.md` and
`share/<plugin>/**` this installer copies into place. Never hand-edit
`dist/opencode/package.json`, `dist/opencode/bin/`, or `dist/opencode/lib/` — edit the
sources here and regenerate.

## Install

```bash
npm install -g claude-plugins-opencode
```

`postinstall` copies the bundled commands and scripts into
`~/.config/opencode/{commands,share}`, substituting the `__PLUGIN_ROOT__` placeholder
each file ships with for the absolute path of its own plugin's installed `share/`
directory. A manifest recording every written path is left at
`~/.config/opencode/.seankoji-plugins-manifest.json`.

If you installed with `--ignore-scripts`, `postinstall` never ran. Run the CLI's own
`install` subcommand instead:

```bash
claude-plugins-opencode install
```

## CLI

```
claude-plugins-opencode install|uninstall|doctor [--prefix <dir>]
```

- `install` — copy commands/scripts into the OpenCode config dir. Idempotent: re-running
  re-substitutes from this package's pristine templates and overwrites the manifest, so
  the result of running twice is the same as running once. Relocating an install (moving
  to a different `--prefix`) requires re-running `install` with the new prefix — nothing
  is moved automatically.
- `uninstall` — removes exactly the files the manifest records, and only files inside the
  resolved install prefix; it refuses (and deletes nothing) if any manifest path resolves
  outside the prefix.
- `doctor` — reports install health, including the specific case of `postinstall` having
  been skipped by `--ignore-scripts`.

`--prefix` (or the `OPENCODE_CONFIG_DIR` environment variable) overrides the default
`~/.config/opencode`.

## Publishing

Manual, via the repo's `workflow_dispatch`-only release workflow — there are no git tags.
The version is authored by hand in `build/npm/package.json` (`docs/MAINTAINING.md` has
the bump procedure) and generated verbatim into `dist/opencode/package.json`.
