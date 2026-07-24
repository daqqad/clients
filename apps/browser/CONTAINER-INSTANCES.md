# Container-aware instance builds (fork)

Stock Bitwarden ignores Firefox containers, and a single extension instance can only have one
account active at a time. This fork adds two things:

1. **Instance builds** — several copies of the extension, each with its own add-on id, name and
   icon. Firefox treats them as unrelated add-ons, so each holds its own account and unlock state.
2. **A container gate** — each build only acts inside the containers it owns. In every other
   container it is completely inert: no autofill scripts injected, no inline menu, no notification
   bar, no badge count, no context-menu entries.

Together these give per-container accounts without touching Bitwarden's account state.

## Configure

`instances.json` defines the builds. `allowedContainers` holds Firefox container names as shown in
the container picker; `default` means tabs in no container. An empty list disables the gate, making
that build behave exactly like stock.

```json
{
  "work": {
    "id": "work",
    "name": "Bitwarden Work",
    "geckoId": "bitwarden-work@containers.local",
    "hue": 18,
    "dotColor": "#F97316",
    "allowedContainers": []
  }
}
```

Container names are usually private, so keep them in `instances.local.json` — it is gitignored and
merged over `instances.json` per instance at build time:

```json
{
  "work": { "allowedContainers": ["Work", "Vendor A"] },
  "personal": { "allowedContainers": ["Personal", "default"] }
}
```

Container names are matched case-insensitively and resolved live, so renaming a container in Firefox
takes effect immediately — but **adding** a container to a build means editing
`instances.local.json` and rebuilding.

`hue` (0-255) and `dotColor` drive the generated toolbar icons: the blue in the stock icon is
hue-shifted, and a colored dot is drawn in the corner so the builds stay distinguishable even in
their gray/locked states.

## Build

```bash
cd apps/browser
npm run build:firefox:instances     # icons + build-work/ + build-personal/
```

Individual builds: `npm run build:firefox:work`, `npm run build:firefox:personal`.
Icons only: `npm run icons:instances` (writes `src/images-instance/<id>/`).

## Sign and install

Firefox will not install unsigned add-ons, so each build needs its own signature from AMO's
`unlisted` channel (automated, no review, free). Credentials are read from
`~/.mozilla/.dev_hub_api_key`, `~/.amo` or `$AMO_CREDENTIALS_FILE`, in that order; JSON, shell and
`JWT issuer: ... / JWT secret: ...` layouts all work:

```bash
AMO_JWT_ISSUER=user:12345678:123
AMO_JWT_SECRET=...
```

Then:

```bash
./scripts/sign-instances.sh            # both, or: ./scripts/sign-instances.sh work
```

Signed XPIs land in `web-ext-artifacts/`. Install by opening each `.xpi` in Firefox. Each new
`geckoId` creates a new add-on entry on the first signing run; later runs upload new versions of it.

## What the gate covers

| Surface                                         | Gated | Where                                                  |
| ----------------------------------------------- | ----- | ------------------------------------------------------ |
| Autofill scripts, inline menu, notification bar | yes   | `platform/services/browser-script-injector.service.ts` |
| Badge match count                               | yes   | `autofill/services/autofill-badge-updater.service.ts`  |
| Context-menu entries                            | yes   | `background/main.background.ts` (`updateContextMenus`) |
| Popup vault list and suggestions                | no    | opening a specific build's popup is an explicit choice |

The gate fails open: an unknown tab, or a browser without containers, counts as owned. It can only
ever narrow what a build already did.

## Known limitations

- The allow list is build-time configuration. There is no settings UI yet, so changing which
  containers a build owns means editing `instances.json` and rebuilding.
- Keyboard shortcuts are stripped from instance builds — only one add-on can hold a given
  accelerator, so siblings would fight over `Ctrl+Shift+L`.
- Desktop/biometric unlock needs the native-messaging host to whitelist each new add-on id, which
  this fork does not do.
- Each instance is a full extension: two installs means two background contexts scanning pages.

## Upstream changes

Everything is additive except three small gate calls. Files touched:

- `instances.json`, `scripts/make-instance-icons.py`, `scripts/sign-instances.sh` (new)
- `webpack.base.js`, `webpack/manifest.js` — instance identity, icon override, `BW_INSTANCE_*` defines
- `src/platform/container/container-gate.service.ts` (new)
- `src/platform/browser/browser-api.ts` — `getTabCookieStoreId`, `getContainerName`
- `src/platform/services/browser-script-injector.service.ts`, `src/autofill/services/autofill-badge-updater.service.ts`, `src/background/main.background.ts` — gate calls

The injector and the context-menu update are the parts most likely to move upstream; check them
after each rebase.
