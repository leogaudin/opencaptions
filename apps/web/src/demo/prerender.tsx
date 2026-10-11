/**
 * The build's way into the page's HTML (see `scripts/demo-prerender.ts`). Not loaded in the browser.
 */
import { renderToString } from "react-dom/server";
import { DemoSkeleton, Page } from "./Landing";

export { headTags } from "./seo";

/** The page's body with the demo's place held, as it is before any script has run. */
export function renderPage(): string {
  return renderToString(<Page demo={<DemoSkeleton />} />);
}
