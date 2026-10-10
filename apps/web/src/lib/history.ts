/**
 * Undo and redo for a value that is replaced whole by each edit. Pure: a `History` goes in
 * and a new one comes out, so the store holds it and a test can walk it.
 *
 * A drag makes dozens of edits a second and should undo as one. An edit may name a `group`,
 * and an edit in the same group soon after the last one joins its step.
 */

/** Edits in one group closer together than this (ms) are one step. */
export const GROUP_WINDOW_MS = 1000;
/** The steps kept; the oldest are forgotten past it. */
export const MAX_STEPS = 100;

export interface History<T> {
  /** Oldest first. */
  past: T[];
  /** Next redo last. */
  future: T[];
  /** The group of the latest edit, and when it happened. */
  group: string | null;
  at: number;
}

export const emptyHistory = <T>(): History<T> => ({ past: [], future: [], group: null, at: 0 });

/** The history after an edit, given the value as it was before it. */
export function recordEdit<T>(
  history: History<T>,
  before: T,
  group: string | null = null,
  now: number = Date.now(),
): History<T> {
  const joins = group !== null && history.group === group && now - history.at < GROUP_WINDOW_MS;
  if (joins) return { ...history, at: now };
  return {
    past: [...history.past, before].slice(-MAX_STEPS),
    future: [],
    group,
    at: now,
  };
}

/** One step back from `current`, or null with nothing to undo. */
export function undo<T>(history: History<T>, current: T): { history: History<T>; value: T } | null {
  const value = history.past[history.past.length - 1];
  if (history.past.length === 0 || value === undefined) return null;
  return {
    value,
    history: {
      past: history.past.slice(0, -1),
      future: [...history.future, current],
      group: null,
      at: 0,
    },
  };
}

/** One step forward from `current`, or null with nothing to redo. */
export function redo<T>(history: History<T>, current: T): { history: History<T>; value: T } | null {
  const value = history.future[history.future.length - 1];
  if (history.future.length === 0 || value === undefined) return null;
  return {
    value,
    history: {
      past: [...history.past, current],
      future: history.future.slice(0, -1),
      group: null,
      at: 0,
    },
  };
}
