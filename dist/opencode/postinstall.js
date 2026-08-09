"use strict";
//
// postinstall.js — runs automatically on `npm install` (unless the install used
// --ignore-scripts, in which case this never fires and `claude-plugins-opencode doctor`
// is how a user is meant to discover that and self-heal with `install`).
//
// Deliberately calls the exact same installer.install() the `install` CLI subcommand
// calls — one implementation, two entry points.
//

const installer = require("./lib/installer.js");

try {
  const manifest = installer.install({});
  console.log(
    `claude-plugins-opencode: installed ${manifest.files.length} file(s) for ${manifest.plugins.length} plugin(s) into ${manifest.prefix}`
  );
  if (manifest.removedOrphans && manifest.removedOrphans.length > 0) {
    console.log(
      `claude-plugins-opencode: removed ${manifest.removedOrphans.length} stale file(s) no longer produced by this package`
    );
  }
} catch (err) {
  console.error(`claude-plugins-opencode postinstall failed: ${err.message}`);
  console.error(
    "claude-plugins-opencode: run `npx claude-plugins-opencode install` to retry, or `npx claude-plugins-opencode doctor` to check install health."
  );
  process.exitCode = 1;
}
