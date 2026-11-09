import assert from "node:assert/strict";
import { test } from "node:test";
import { describeLook, describeStyle, findLook, LOOKS, STYLE_SCHEMA } from "../src/looks.ts";

test("a look is found by its name or id, in any case", () => {
  assert.equal(findLook("purple punch").id, "builtin:purple-punch");
  assert.equal(findLook("builtin:bold").name, "Bold");
  assert.equal(findLook("TITLE-CARD").name, "Title Card");
});

test("every look has a line, and every setting a meaning", () => {
  assert.equal(LOOKS.length, 19);
  for (const look of LOOKS) assert.match(describeLook(look), new RegExp(`^${look.name}: `));
  const lines = describeStyle().split("\n");
  assert.equal(
    lines.length,
    Object.keys((STYLE_SCHEMA as { properties: object }).properties).length,
  );
  for (const line of lines) assert.doesNotMatch(line, /undefined/);
});

test("a tool's style settings are all optional", () => {
  assert.equal("required" in STYLE_SCHEMA, false);
});
