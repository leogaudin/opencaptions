/**
 * The language step of a transcription: which languages a model can be asked for, where the choice
 * starts, and a flag for each (the iPhone app shows the same list the same way). There is no
 * "detect it" choice: a language is always chosen.
 */

/** The languages a model can be asked for: all of them when it names none (Whisper takes any). */
export function languagesForModel<L extends { code: string }>(
  all: readonly L[],
  models: readonly { id: string; languages?: readonly string[] | null }[],
  modelId: string,
): L[] {
  const only = models.find((m) => m.id === modelId)?.languages;
  return only ? all.filter((l) => only.includes(l.code)) : [...all];
}

/**
 * Where the choice starts: the one remembered if the model offers it, else the browser's language,
 * else the first on the list. `offered` may be empty (the settings could not be read): the
 * browser's language is then used as it is.
 */
export function startingLanguage(
  offered: readonly { code: string }[],
  stored: string | null,
  browser: readonly string[],
): string {
  const has = (code: string | null | undefined): code is string =>
    !!code && offered.some((l) => l.code === code);
  if (has(stored)) return stored;
  for (const tag of browser) {
    const code = tag.toLowerCase().split("-")[0];
    if (has(code)) return code;
  }
  return offered[0]?.code ?? browser[0]?.toLowerCase().split("-")[0] ?? "en";
}

/** The country a language's flag stands for, where it has a natural one. */
const REGIONS: Record<string, string> = {
  en: "GB",
  zh: "CN",
  de: "DE",
  es: "ES",
  ru: "RU",
  ko: "KR",
  fr: "FR",
  ja: "JP",
  pt: "BR",
  tr: "TR",
  pl: "PL",
  ca: "AD",
  nl: "NL",
  ar: "SA",
  sv: "SE",
  it: "IT",
  id: "ID",
  hi: "IN",
  fi: "FI",
  vi: "VN",
  he: "IL",
  uk: "UA",
  el: "GR",
  ms: "MY",
  cs: "CZ",
  ro: "RO",
  da: "DK",
  hu: "HU",
  ta: "IN",
  no: "NO",
  th: "TH",
  ur: "PK",
  hr: "HR",
  bg: "BG",
  lt: "LT",
  la: "VA",
  mi: "NZ",
  ml: "IN",
  sk: "SK",
  te: "IN",
  fa: "IR",
  lv: "LV",
  bn: "BD",
  sr: "RS",
  az: "AZ",
  sl: "SI",
  kn: "IN",
  et: "EE",
  mk: "MK",
  br: "FR",
  eu: "ES",
  is: "IS",
  hy: "AM",
  ne: "NP",
  mn: "MN",
  bs: "BA",
  kk: "KZ",
  sq: "AL",
  sw: "KE",
  gl: "ES",
  mr: "IN",
  pa: "IN",
  si: "LK",
  km: "KH",
  sn: "ZW",
  yo: "NG",
  so: "SO",
  af: "ZA",
  oc: "FR",
  ka: "GE",
  be: "BY",
  tg: "TJ",
  sd: "PK",
  gu: "IN",
  am: "ET",
  yi: "IL",
  lo: "LA",
  uz: "UZ",
  fo: "FO",
  ht: "HT",
  ps: "AF",
  tk: "TM",
  nn: "NO",
  mt: "MT",
  sa: "IN",
  lb: "LU",
  my: "MM",
  tl: "PH",
  mg: "MG",
  as: "IN",
  tt: "RU",
  haw: "US",
  ln: "CD",
  ha: "NG",
  ba: "RU",
  jw: "ID",
  su: "ID",
  yue: "HK",
};

/** The flag emoji for a language code, or a globe when the language has no country of its own. */
export function languageFlag(code: string): string {
  // Wales: a flag is an emoji tag sequence, not a pair of regional letters.
  if (code === "cy") return "\u{1F3F4}\u{E0067}\u{E0062}\u{E0077}\u{E006C}\u{E0073}\u{E007F}";
  const region = REGIONS[code];
  if (!region) return "\u{1F310}";
  return String.fromCodePoint(...[...region].map((c) => 0x1f1e6 + c.charCodeAt(0) - 0x41));
}
