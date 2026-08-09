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
  // Exit 0 on failure, deliberately. A non-zero postinstall fails the whole
  // `npm install`, and npm then removes the package — so an unwritable config dir
  // (CI, a Docker layer, restricted permissions) would leave the user with nothing
  // installed and no CLI to recover with. Exiting 0 keeps the package on disk so
  // `claude-plugins-opencode doctor` can report the gap and `install` can self-heal
  // once the environment is fixed; doctor already treats "package present, nothing
  // installed" as the --ignore-scripts case and says so.
  //
  // The recovery hint must not name `npx claude-plugins-opencode ...`: for a package
  // that failed to install, npx re-fetches and re-runs this same postinstall, so both
  // commands would re-trigger the failure. Name the installed binary instead.
  console.error(`claude-plugins-opencode postinstall failed: ${err.message}`);
  console.error(
    "claude-plugins-opencode: the package is still installed. Fix the cause above, then run `claude-plugins-opencode install` to retry, or `claude-plugins-opencode doctor` to check install health."
  );
}
