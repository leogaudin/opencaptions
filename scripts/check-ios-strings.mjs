// Fail if an iOS permission purpose string is missing, is its own key name, or is too short to
// say what the data is used for. App Review rejects those, and the English build falls back to the
// key when InfoPlist.xcstrings has no "en" entry.
import { readFileSync } from "node:fs";

const root = new URL("..", import.meta.url).pathname;
const read = (p) => readFileSync(root + p, "utf8");

const keys = new Set([
  ...[...read("apps/ios/project.yml").matchAll(/INFOPLIST_KEY_(NS\w+UsageDescription):/g)].map((m) => m[1]),
  ...[...read("apps/ios/Config/Info.plist").matchAll(/<key>(NS\w+UsageDescription)<\/key>/g)].map((m) => m[1]),
]);
const catalog = JSON.parse(read("apps/ios/OpenCaptions/Resources/InfoPlist.xcstrings")).strings;
const MIN_WORDS = 5;

const problems = [];
for (const key of keys) {
  const locales = catalog[key]?.localizations;
  if (!locales) {
    problems.push(`${key}: no entry in InfoPlist.xcstrings`);
    continue;
  }
  if (!locales.en) problems.push(`${key}: no "en" value, so English builds show the key name`);
  for (const [lang, { stringUnit }] of Object.entries(locales)) {
    const value = (stringUnit?.value ?? "").trim();
    if (!value || value === key) problems.push(`${key} [${lang}]: empty or the key itself`);
    else if (lang === "en" && value.split(/\s+/).length < MIN_WORDS)
      problems.push(`${key} [en]: "${value}" is too short to explain the use`);
  }
}
for (const key of Object.keys(catalog))
  if (!keys.has(key)) problems.push(`${key}: in InfoPlist.xcstrings but not declared by the app`);

if (problems.length) {
  console.error(`iOS purpose strings:\n  ${problems.join("\n  ")}`);
  process.exit(1);
}
console.log(`iOS purpose strings OK (${keys.size} keys)`);
