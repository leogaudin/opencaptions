import { Loader2, Moon, Sun } from "lucide-react";
/**
 * Application shell: session bootstrap, route guards, router + layout chrome.
 *
 * Auth-gated: on first load we resolve session state (GET /auth/status +
 * /auth/me) BEFORE rendering routes, so a logged-out visitor never sees the app
 * shell flash and an authenticated one never sees a login flash.
 */
import { type ReactNode, useEffect, useRef, useState } from "react";
import { BrowserRouter, Link, Navigate, Route, Routes, useLocation } from "react-router-dom";
import { AboutDialog, AboutTrigger } from "@/components/AboutDialog";
import { UserMenu } from "@/components/UserMenu";
import * as api from "@/lib/api";
import { iconButtonClass, shellX } from "@/lib/ui";
import { useTheme } from "@/lib/useTheme";
import { AccountPage } from "@/pages/AccountPage";
import { EditorPage } from "@/pages/EditorPage";
import { ForgotPasswordPage } from "@/pages/ForgotPasswordPage";
import { HomePage } from "@/pages/HomePage";
import { LoginPage } from "@/pages/LoginPage";
import { ResetPasswordPage } from "@/pages/ResetPasswordPage";
import { SignupPage } from "@/pages/SignupPage";
import { UploadPage } from "@/pages/UploadPage";
import { useAuthStore } from "@/store/authStore";

export function App() {
  const phase = useAuthStore((s) => s.phase);
  const bootstrap = useAuthStore((s) => s.bootstrap);
  const started = useRef(false);

  // Resolve session state exactly once on first mount (StrictMode double-invokes
  // effects in dev — the ref guard keeps it to a single status+me probe).
  useEffect(() => {
    if (started.current) return;
    started.current = true;
    bootstrap();
  }, [bootstrap]);

  // Central 401 → clear auth; the route guards then redirect to login. Registered
  // once. The bootstrap /auth/me probe opts out via skipAuthRedirect.
  useEffect(() => {
    api.setUnauthorizedHandler(() => useAuthStore.getState().clearSession());
    return () => api.setUnauthorizedHandler(null);
  }, []);

  // Until the session resolves, render a neutral splash — no shell, no login.
  if (phase === "bootstrapping") {
    return <BootstrapSplash />;
  }

  return (
    <BrowserRouter>
      <Routes>
        <Route
          path="/login"
          element={
            <RedirectIfAuthenticated>
              <LoginPage />
            </RedirectIfAuthenticated>
          }
        />
        <Route
          path="/signup"
          element={
            <RedirectIfAuthenticated>
              <SignupPage />
            </RedirectIfAuthenticated>
          }
        />
        <Route
          path="/forgot-password"
          element={
            <RedirectIfAuthenticated>
              <ForgotPasswordPage />
            </RedirectIfAuthenticated>
          }
        />
        <Route
          path="/reset-password"
          element={
            <RedirectIfAuthenticated>
              <ResetPasswordPage />
            </RedirectIfAuthenticated>
          }
        />
        <Route
          path="/*"
          element={
            <RequireAuth>
              <AppShell />
            </RequireAuth>
          }
        />
      </Routes>
    </BrowserRouter>
  );
}

/** Full-screen neutral loader shown while the session is being resolved. */
function BootstrapSplash() {
  return (
    <output className="flex h-screen w-full items-center justify-center bg-background text-foreground">
      <Loader2 className="mr-2 h-5 w-5 animate-spin text-muted-foreground" aria-hidden />
      <span className="text-sm text-muted-foreground">Loading…</span>
    </output>
  );
}

/**
 * Guard for protected routes. Unauthenticated visitors are redirected to the
 * right auth screen — signup on a first-run instance, otherwise login —
 * preserving the intended destination so a deep link survives the round trip.
 */
function RequireAuth({ children }: { children: ReactNode }) {
  const phase = useAuthStore((s) => s.phase);
  const setupRequired = useAuthStore((s) => s.status?.setup_required ?? false);
  const location = useLocation();
  if (phase !== "authenticated") {
    const to = setupRequired ? "/signup" : "/login";
    const from = `${location.pathname}${location.search}`;
    return <Navigate to={to} replace state={{ from }} />;
  }
  return <>{children}</>;
}

/**
 * Guard for the auth screens: an already-authenticated user is sent straight to
 * their intended destination (or home), so login/signup never flash for them.
 */
function RedirectIfAuthenticated({ children }: { children: ReactNode }) {
  const phase = useAuthStore((s) => s.phase);
  const location = useLocation();
  if (phase === "authenticated") {
    const from = (location.state as { from?: string } | null)?.from;
    return <Navigate to={from ?? "/"} replace />;
  }
  return <>{children}</>;
}

/** Authenticated application shell: header + routed main content. */
function AppShell() {
  return (
    <div className="flex h-screen flex-col bg-background text-foreground">
      <Header />
      <main className="flex min-h-0 flex-1 flex-col">
        <Routes>
          <Route path="/" element={<HomePage />} />
          <Route path="/upload" element={<UploadPage />} />
          <Route path="/account" element={<AccountPage />} />
          <Route path="/projects/:projectId" element={<EditorPage />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </main>
    </div>
  );
}

function Header() {
  const { theme, toggle } = useTheme();
  const [aboutOpen, setAboutOpen] = useState(false);
  // Runtime details are a self-hoster's business; a hosted instance keeps
  // its infrastructure to itself (the API withholds them too).
  const hostedMode = useAuthStore((s) => s.status?.hosted_mode ?? false);

  return (
    <header className="bg-background">
      {/* Full-bleed row (no centred max-width cap): the wordmark hugs the left
          and the nav cluster hugs the right at a deliberate, constant inset at
          every width. This wrapper's padding is identical to each page's outer
          padding (shellX), so the header's left/right edges line up exactly with
          the page content below it. */}
      <div className={`flex h-14 w-full items-center justify-between ${shellX}`}>
        {/* Wordmark styled as a native burned-in subtitle cue: pure monochrome
            block with square corners — no rounding, no tint, no accent colour. */}
        <Link
          to="/"
          className="inline-flex items-baseline bg-black px-2 py-0.5 text-base font-bold leading-none tracking-tight text-white dark:bg-white dark:text-black"
        >
          OpenCaptions
          <span aria-hidden="true" className="ml-px">
            .
          </span>
        </Link>
        {/* Nav cluster: sits at the right edge of the full-bleed header, a
            constant inset from the viewport at every width, aligned with the
            page content and toolbar actions below. */}
        <nav className="flex items-center gap-2 text-sm">
          <Link to="/" className="text-muted-foreground hover:text-foreground">
            Projects
          </Link>
          <Link
            to="/upload"
            className="rounded-xl bg-primary px-4 py-2 text-sm font-bold text-primary-foreground transition-opacity hover:opacity-90"
          >
            New project
          </Link>
          {!hostedMode && <AboutTrigger onClick={() => setAboutOpen(true)} />}
          <button
            type="button"
            onClick={toggle}
            aria-label={theme === "dark" ? "Switch to light mode" : "Switch to dark mode"}
            title={theme === "dark" ? "Switch to light mode" : "Switch to dark mode"}
            className={iconButtonClass}
          >
            {theme === "dark" ? (
              <Sun className="h-4 w-4" aria-hidden />
            ) : (
              <Moon className="h-4 w-4" aria-hidden />
            )}
          </button>
          {/* Identity + sign-out collapsed into one silhouette icon button that
              opens a menu (see UserMenu): shows who you're signed in as and a way
              out, with room to hang future account actions. Follows the non-accent
              icon-button hierarchy — never accent. */}
          <UserMenu />
        </nav>
      </div>
      <AboutDialog open={aboutOpen} onOpenChange={setAboutOpen} />
    </header>
  );
}
