/**
 * Auth / session store.
 *
 * WHY A SEPARATE STORE (not editorStore): the session is an app-lifetime,
 * cross-cutting concern, orthogonal to editing one project. editorStore is
 * `reset()` every time the editor unmounts: folding auth into it would risk
 * wiping the session on navigation, and would couple the editor's autosave
 * machinery to auth. The CSRF token itself lives in the api client's memory
 * (single source of truth, never localStorage); this store holds only the user
 * and the public status flags the router needs.
 *
 * Zustand identity note: consumers MUST select primitives (s.phase,
 * s.user?.email, s.status?.setup_required) and MUST NOT put the whole
 * `user` / `status` object into a hook dependency array.
 */
import { create } from "zustand";
import * as api from "@/lib/api";
import type { AuthStatus, AuthUser } from "@/types/auth";

/** Where the app is in resolving/holding a session. */
export type AuthPhase = "bootstrapping" | "authenticated" | "unauthenticated";

interface AuthState {
  phase: AuthPhase;
  user: AuthUser | null;
  /** Public instance flags from GET /auth/status; null until resolved. */
  status: AuthStatus | null;

  /** First-load resolution: status → me. Never rejects; always resolves phase. */
  bootstrap: () => Promise<void>;
  /** Re-fetch the public status flags. */
  refreshStatus: () => Promise<void>;
  /** Log in; throws on failure so the screen can surface a generic error. */
  login: (email: string, password: string) => Promise<void>;
  /** Register a new account (ordinary user). Throws on failure. */
  register: (email: string, password: string) => Promise<void>;
  /** Log out (best-effort server call) and drop local session state. */
  logout: () => Promise<void>;
  /** Drop local session state without a server call, used by the central 401 handler. */
  clearSession: () => void;
  /** Replace the held user after the account page changes it. */
  setUser: (user: AuthUser) => void;
}

export const useAuthStore = create<AuthState>((set) => ({
  phase: "bootstrapping",
  user: null,
  status: null,

  bootstrap: async () => {
    set({ phase: "bootstrapping" });
    // Public status first, tells us first-run vs returning, and whether open
    // registration is available. Non-fatal if it fails (backend still starting):
    // guards then fall back to the login screen rather than an infinite spinner.
    try {
      const status = await api.getAuthStatus();
      set({ status });
    } catch {
      /* leave status null */
    }
    // Resolve the session from the httpOnly cookie. A 401 here is EXPECTED when
    // logged out and must not redirect (fetchMe passes skipAuthRedirect).
    try {
      const session = await api.fetchMe();
      set({ user: session.user, phase: "authenticated" });
    } catch {
      set({ user: null, phase: "unauthenticated" });
    }
  },

  refreshStatus: async () => {
    try {
      const status = await api.getAuthStatus();
      set({ status });
    } catch {
      /* non-fatal */
    }
  },

  login: async (email, password) => {
    const session = await api.login(email, password);
    set({ user: session.user, phase: "authenticated" });
  },

  register: async (email, password) => {
    const session = await api.register(email, password);
    // The first account flips setup_required off; keep local status coherent for
    // any screen still reading it. Best-effort so registration UX never blocks.
    set((s) => ({
      user: session.user,
      phase: "authenticated",
      status: s.status ? { ...s.status, setup_required: false } : s.status,
    }));
  },

  logout: async () => {
    try {
      await api.logout();
    } finally {
      set({ user: null, phase: "unauthenticated" });
    }
  },

  clearSession: () => {
    // The CSRF token lives in the api client's memory, not this store; clearing
    // only user/phase here would leave a stale token attached to later requests.
    // Drop it too so clearSession fully tears the session down.
    api.setCsrfToken(null);
    set({ user: null, phase: "unauthenticated" });
  },

  setUser: (user) => set({ user }),
}));
