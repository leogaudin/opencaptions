/**
 * Time formatting. Relative times for list timestamps ("2 days ago", "just now"),
 * replacing raw locale strings like "8/28/2026, 4:00:42 PM", use the platform
 * Intl.RelativeTimeFormat so output is locale-aware with no dependencies.
 */
const rtf = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });

const DIVISIONS: { amount: number; unit: Intl.RelativeTimeFormatUnit }[] = [
  { amount: 60, unit: "second" },
  { amount: 60, unit: "minute" },
  { amount: 24, unit: "hour" },
  { amount: 7, unit: "day" },
  { amount: 4.34524, unit: "week" },
  { amount: 12, unit: "month" },
  { amount: Number.POSITIVE_INFINITY, unit: "year" },
];

/**
 * Format an ISO-8601 timestamp as a relative time from now. Returns "" for an
 * unparseable input so callers can fall back cleanly (never renders "Invalid
 * Date").
 */
export function formatRelativeTime(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "";
  // seconds; negative = in the past (which is the normal case for timestamps)
  let duration = (date.getTime() - Date.now()) / 1000;
  for (const division of DIVISIONS) {
    if (Math.abs(duration) < division.amount) {
      return rtf.format(Math.round(duration), division.unit);
    }
    duration /= division.amount;
  }
  return "";
}

/** A position in a video as `m:ss.cc`, the hundredths a caption edit is judged by. */
export function formatTimecode(seconds: number): string {
  const total = Math.max(0, Number.isFinite(seconds) ? seconds : 0);
  const cs = Math.floor(total * 100);
  const [m, s, c] = [Math.floor(cs / 6000), Math.floor((cs % 6000) / 100), cs % 100];
  return `${m}:${String(s).padStart(2, "0")}.${String(c).padStart(2, "0")}`;
}
