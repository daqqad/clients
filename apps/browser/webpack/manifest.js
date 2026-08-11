/**
 * Transform the manifest template into a browser specific manifest.
 *
 * We support a simple browser prefix to the manifest keys. Example:
 *
 * ```json
 * {
 *   "name": "Default name",
 *   "__chrome__name": "Chrome override"
 * }
 * ```
 *
 * Will result in the following manifest:
 *
 * ```json
 * {
 *  "name": "Chrome override"
 * }
 * ```
 *
 * for Chrome.
 */
function transform(browser, instance) {
  return (buffer) => {
    let manifest = JSON.parse(buffer.toString());

    manifest = transformPrefixes(manifest, browser);
    manifest = applyInstance(manifest, instance, browser);

    return JSON.stringify(manifest, null, 2);
  };
}

/**
 * Give a side-by-side instance build its own add-on identity.
 *
 * A distinct gecko id makes Firefox treat the build as a separate add-on, so it
 * gets its own storage and background context and can stay logged into a
 * different account than its siblings. Keyboard shortcuts are dropped because
 * only one add-on can hold a given accelerator.
 */
function applyInstance(manifest, instance, browser) {
  if (instance == null) {
    return manifest;
  }

  // Resolving a tab's container to a name needs contextualIdentities, which only
  // exists on Firefox. Added here so stock builds keep their permission set.
  if (browser === "firefox" && instance.allowedContainers?.length > 0) {
    manifest.permissions = [...manifest.permissions, "contextualIdentities"];
  }

  manifest.name = instance.name;
  manifest.short_name = instance.shortName ?? instance.name;

  // AMO refuses a version it has already signed, and upstream's version is
  // reused across rebuilds, so instance builds carry a fourth component that is
  // bumped per upload. Firefox treats 2026.7.0.2 as newer than 2026.7.0.1, so
  // installing the new xpi upgrades in place and keeps the vault session.
  if (instance.build != null) {
    manifest.version = `${manifest.version}.${instance.build}`;
  }

  if (manifest.browser_action != null) {
    manifest.browser_action.default_title = instance.name;
  }
  if (manifest.action != null) {
    manifest.action.default_title = instance.name;
  }
  if (manifest.sidebar_action != null) {
    manifest.sidebar_action.default_title = instance.name;
  }
  if (manifest.browser_specific_settings?.gecko != null) {
    manifest.browser_specific_settings.gecko.id = instance.geckoId;

    // Self-distributed builds get no updates from AMO. Firefox polls this
    // manifest roughly daily and installs whatever version it advertises. Kept
    // in instances.local.json because the URL is unlisted.
    if (instance.updateUrl) {
      manifest.browser_specific_settings.gecko.update_url = instance.updateUrl;
    }
  }

  delete manifest.commands;

  return manifest;
}

const browsers = ["chrome", "edge", "firefox", "opera", "safari"];

/**
 * Flatten the browser prefixes in the manifest.
 *
 * - Removes unrelated browser prefixes.
 * - A null value deletes the non prefixed key.
 */
function transformPrefixes(manifest, browser) {
  const prefix = `__${browser}__`;

  function transformObject(obj) {
    return Object.keys(obj).reduce((acc, key) => {
      // Determine if we need to recurse into the object.
      const nested = typeof obj[key] === "object" && obj[key] !== null && !Array.isArray(obj[key]);

      if (key.startsWith(prefix)) {
        const newKey = key.slice(prefix.length);

        // Null values are used to remove keys.
        if (obj[key] == null) {
          delete acc[newKey];
          return acc;
        }

        acc[newKey] = nested ? transformObject(obj[key]) : obj[key];
      } else if (!browsers.some((b) => key.startsWith(`__${b}__`))) {
        acc[key] = nested ? transformObject(obj[key]) : obj[key];
      }

      return acc;
    }, {});
  }

  return transformObject(manifest);
}

module.exports = {
  transform,
};
