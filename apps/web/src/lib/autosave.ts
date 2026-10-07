/**
 * Debounced autosave that only saves when something actually changed.
 *
 * "Changed" is judged against a snapshot of the last saved state, not a dirty
 * flag, because a save's own response updates the store, a flag would retrigger
 * forever. A save can also be held while `isBlocked()` (a render in flight must
 * not have its inputs changed under it) and runs once `release()` is called.
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
  /** Drop any pending save and forget the saved state. */
  reset: () => void;
}

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

  const snapshot = () => JSON.stringify(read());
  const changed = () => snapshot() !== saved;
  const cancel = () => {
    if (timer) clearTimeout(timer);
    timer = null;
  };

  const run = async () => {
    const next = snapshot();
    if (await save()) saved = next;
  };

  const autosave: Autosave = {
    schedule: () => {
      if (isBlocked()) {
        deferred = true;
        return;
      }
      if (!changed()) return;
      cancel();
      timer = setTimeout(() => {
        timer = null;
        if (changed()) void run();
      }, delayMs);
    },
    flush: async () => {
      cancel();
      if (changed()) await run();
    },
    release: () => {
      if (!deferred) return;
      deferred = false;
      autosave.schedule();
    },
    markSaved: () => {
      saved = snapshot();
    },
    reset: () => {
      cancel();
      deferred = false;
      saved = null;
    },
  };
  return autosave;
}
