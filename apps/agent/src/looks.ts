/**
 * The built-in looks (the same file the web and the iPhone app read, copied by
 * scripts/generate-api-types.sh) and the style settings, described from the API's own schema.
 */
import type { StyleConfig } from "./client.ts";
import { OpenCaptionsError } from "./client.ts";
import presets from "./generated/presets.json" with { type: "json" };
import schemas from "./generated/schemas.json" with { type: "json" };

export interface Look {
  id: string;
  name: string;
  config: StyleConfig;
}

export const LOOKS = presets as Look[];

/** A look by its name or id, in any case: "Bold", "bold" and "builtin:bold" are the same. */
export function findLook(name: string): Look {
  const wanted = name.trim().toLowerCase();
  const look = LOOKS.find(
    (l) => l.name.toLowerCase() === wanted || l.id === wanted || l.id === `builtin:${wanted}`,
  );
  if (!look) {
    throw new OpenCaptionsError(
      `There is no look called "${name}". The looks: ${LOOKS.map((l) => l.name).join(", ")}.`,
    );
  }
  return look;
}

/** One line on a look: its name, then what makes it what it is. */
export function describeLook(look: Look): string {
  const c = look.config;
  const parts = [c.animation, c.font, ...(c.text_case === "upper" ? ["capitals"] : [])];
  if (c.background && c.background !== "none") parts.push(`${c.background} background`);
  parts.push(`highlight ${(c.highlight_colors ?? []).join(" ")}`);
  if ((c.variants ?? []).length > 0) parts.push(`${c.variants?.length} word looks dealt at random`);
  return `${look.name}: ${parts.join(", ")}`;
}

interface Property {
  type?: string;
  enum?: unknown[];
  anyOf?: Property[];
  items?: Property;
  minimum?: number;
  maximum?: number;
  maxItems?: number;
  pattern?: string;
  default?: unknown;
  description?: string;
}

/** The style's JSON schema, every setting optional: what a tool takes as changes to a look. */
export const STYLE_SCHEMA = (() => {
  const { required: _required, ...schema } = schemas.style as { required?: string[] };
  return schema;
})();

/** The save options' JSON schema (format, size, frame rate, captions only). */
export const SAVE_SCHEMA = schemas.save as { properties: Record<string, Property> };

/** Every style setting with its type, range and meaning, one per line. */
export function describeStyle(): string {
  const properties = (schemas.style as { properties: Record<string, Property> }).properties;
  return Object.entries(properties)
    .map(
      ([name, p]) => `${name} (${kind(p)}, default ${JSON.stringify(p.default)}): ${p.description}`,
    )
    .join("\n");
}

function kind(p: Property): string {
  if (p.enum) return `one of ${p.enum.join(", ")}`;
  if (p.type === "array") {
    if (p.items?.pattern) return `up to ${p.maxItems} colours #RRGGBB`;
    return `up to ${p.maxItems} word looks`;
  }
  if (p.pattern)
    return p.pattern.includes("{2}") ? "colour #RRGGBB or #RRGGBBAA" : "colour #RRGGBB";
  if (p.minimum !== undefined) return `${p.type} ${p.minimum} to ${p.maximum}`;
  return p.type ?? "value";
}

/** A look with changes over it; settings left out are the look's. */
export function styleFor(
  look: string | undefined,
  changes: Partial<StyleConfig> = {},
): StyleConfig {
  const base = findLook(look ?? LOOKS[0]?.name ?? "").config;
  return { ...base, ...changes };
}
