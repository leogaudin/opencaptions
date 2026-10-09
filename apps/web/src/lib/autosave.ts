/**
 * Debounced autosave that only saves when something actually changed.
 *
 * "Changed" is judged against a snapshot of the last saved state, not a dirty
 * flag, because a save's own response updates the store, a flag would retrigger
 * forever. A save can also be held while `isBlocked()` (a render in flight must
 * not have its inputs changed under it) and runs once `release()` is called.
 *
 * Saves never overlap: an edit made while one is in flight waits for it and is
 * saved right after, so two requests cannot land out of order. A failed save is
 * retried with a growing delay for as long as something is unsaved.
 */
export interface Autosave {
  /** Save after `delayMs` of quiet, unless blocked or unchanged. */
  schedule: () => void;
  /** Save now if anything changed; resolves once it has. */
  flush: () => Promise<void>;
  /** Run a save deferred by `isBlocked`. */
  release: () => void;
  /** Record the current state as saved, without saving. */
  markSaved: () => void;
  /** Whether the current state differs from the last saved one. */
  dirty: () => boolean;
  /** Drop any pending save and forget the saved state. */
  reset: () => void;
}

const MAX_RETRY_MS = 30_000;

export function createAutosave<T>({
  delayMs,
  read,
  save,
  isBlocked,
}: {
  delayMs: number;
  read: () => T;
  /** Resolves true on success; a failed save leaves the state unsaved. */
  save: () => Promise<boolean>;
  isBlocked: () => boolean;
}): Autosave {
  let timer: ReturnType<typeof setTimeout> | null = null;
  let deferred = false;
  let saved: string | null = null;
  let inflight: Promise<void> | null = null;
  let failures = 0;
  // Bumped by reset(), so a save that finishes after it records nothing.
  let epoch = 0;

  const snapshot = () => JSON.stringify(read());
  const changed = () => snapshot() !== saved;
  const cancel = () => {
    if (timer) clearTimeout(timer);
    timer = null;
  };

  const arm = (ms: number) => {
    cancel();
    timer = setTimeout(() => {
      timer = null;
      if (changed()) void run();
    }, ms);
  };

  /** Saves until nothing is left unsaved; concurrent callers share the one loop. */
  const run = (): Promise<void> => {
    if (inflight) return inflight;
    const mine = epoch;
    inflight = (async () => {
      try {
        while (mine === epoch && changed()) {
          const next = snapshot();
          const ok = await save();
          if (mine !== epoch) return;
          if (!ok) {
            failures++;
            if (isBlocked()) deferred = true;
            else arm(Math.min(MAX_RETRY_MS, delayMs * 2 ** failures));
            return;
          }
          failures = 0;
          saved = next;
        }
      } finally {
        if (mine === epoch) inflight = null;
      }
    })();
    return inflight;
  };

  const autosave: Autosave = {
    schedule: () => {
      if (isBlocked()) {
        deferred = true;
        return;
      }
      if (!changed()) return;
      arm(delayMs);
    },
    flush: async () => {
      cancel();
      await run();
    },
    release: () => {
      if (!deferred) return;
      deferred = false;
      autosave.schedule();
    },
    markSaved: () => {
      saved = snapshot();
    },
    dirty: changed,
    reset: () => {
      cancel();
      deferred = false;
      saved = null;
      failures = 0;
      inflight = null;
      epoch++;
    },
  };
  return autosave;
}
