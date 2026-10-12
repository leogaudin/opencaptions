/**
 * Lets the pages stay plain Markdown that GitHub shows too. Two things GitHub needs differently
 * from the site, bridged here:
 *  - a page links another with a relative `.md` link (GitHub follows it); the site wants its URL.
 *  - a page starts with its own `# Title` (GitHub shows it); Starlight draws the title itself.
 * A link to a page that is not there stops the build, so a rename cannot leave a dead link.
 */
import { existsSync } from "node:fs";
import { dirname, relative, resolve, sep } from "node:path";

interface Node {
  type: string;
  url?: string;
  depth?: number;
  children?: Node[];
}

const root = resolve("src/content/docs");
const pageLink = /^(?![a-z][a-z0-9+.-]*:|[/#])([^#?]+\.md)(#.*)?$/i;

function rewrite(node: Node, from: string): void {
  if (node.type === "link" && node.url) {
    const found = pageLink.exec(node.url);
    if (found) {
      const target = resolve(dirname(from), found[1]);
      if (!existsSync(target)) throw new Error(`${from}: the link ${node.url} goes to no page`);
      const page = relative(root, target).split(sep).join("/").replace(/(^|\/)index\.md$|\.md$/, "");
      node.url = `/${page}${page ? "/" : ""}${found[2] ?? ""}`;
    }
  }
  for (const child of node.children ?? []) rewrite(child, from);
}

export function remarkDocs() {
  return (tree: Node, file: { path: string }): void => {
    const first = tree.children?.[0];
    if (first?.type === "heading" && first.depth === 1) tree.children?.shift();
    rewrite(tree, file.path);
  };
}
