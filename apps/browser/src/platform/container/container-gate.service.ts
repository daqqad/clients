import { BrowserApi } from "../browser/browser-api";

/**
 * Name used for tabs that belong to no Firefox container.
 */
export const DEFAULT_CONTAINER_NAME = "default";

/**
 * Restricts an instance build to a set of Firefox containers.
 *
 * Several builds of this extension can be installed side by side, each signed
 * with its own add-on id and therefore holding its own account. This service
 * decides whether a given tab belongs to the containers a build owns, so the
 * other builds stay completely inert there: no injected autofill scripts, no
 * inline menu, no badge count and no autofill suggestions.
 *
 * The allow list is baked in at build time from instances.json. An empty list
 * disables the gate entirely, which is how stock builds behave.
 */
export class ContainerGateService {
  private readonly allowedContainers: string[] = JSON.parse(
    process.env.BW_INSTANCE_CONTAINERS || "[]",
  ).map((name: string) => name.toLowerCase());

  /**
   * False when this build owns every container, in which case callers can skip
   * the lookup entirely.
   */
  get active(): boolean {
    return this.allowedContainers.length > 0;
  }

  /**
   * Whether this build is responsible for the given tab.
   *
   * Fails open: an unknown tab, or a browser without containers, is treated as
   * owned so the gate can only ever narrow what a build already did.
   */
  async allowsTab(tab: chrome.tabs.Tab): Promise<boolean> {
    if (!this.active || tab == null) {
      return true;
    }

    const cookieStoreId = BrowserApi.getTabCookieStoreId(tab);
    if (cookieStoreId == null) {
      return true;
    }

    return await this.allowsCookieStore(cookieStoreId);
  }

  /**
   * Whether this build is responsible for the given tab id. Prefer
   * {@link allowsTab} when the tab object is already at hand.
   */
  async allowsTabId(tabId: number): Promise<boolean> {
    if (!this.active) {
      return true;
    }

    return await this.allowsTab(tabId && (await BrowserApi.getTab(tabId)));
  }

  async allowsCookieStore(cookieStoreId: string): Promise<boolean> {
    if (!this.active) {
      return true;
    }

    // Not cached: the lookup is a cheap local call, and a cache would go stale
    // whenever a container is renamed.
    const name = (await BrowserApi.getContainerName(cookieStoreId)) ?? DEFAULT_CONTAINER_NAME;

    return this.allowedContainers.includes(name.toLowerCase());
  }
}

/**
 * Shared instance. The gate is read-only build configuration, so background and
 * popup contexts can each hold their own copy without coordinating.
 */
export const containerGate = new ContainerGateService();
