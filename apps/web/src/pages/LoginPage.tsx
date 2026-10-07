/**
 * Login screen. Shares layout + validation with the signup screen.
 *
 * Failure is surfaced GENERICALLY: never revealing whether the email exists.
 * On success, phase flips to "authenticated" and the RedirectIfAuthenticated
 * guard wrapping this page navigates to the intended destination.
 */
import { type FormEvent, useEffect, useRef, useState } from "react";
import { Link, Navigate, useLocation } from "react-router-dom";
import { AuthLayout } from "@/components/AuthLayout";
import { ApiException } from "@/lib/api";
import { validateEmail, validatePassword } from "@/lib/authValidation";
import { useAuthStore } from "@/store/authStore";

export function LoginPage() {
  const login = useAuthStore((s) => s.login);
  const setupRequired = useAuthStore((s) => s.status?.setup_required ?? false);
  const registrationEnabled = useAuthStore((s) => s.status?.registration_enabled ?? false);
  const resetAvailable = useAuthStore((s) => s.status?.reset_available ?? false);
  const location = useLocation();

  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [emailError, setEmailError] = useState<string | null>(null);
  const [passwordError, setPasswordError] = useState<string | null>(null);
  const [formError, setFormError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  const emailRef = useRef<HTMLInputElement>(null);
  const passwordRef = useRef<HTMLInputElement>(null);
  useEffect(() => {
    emailRef.current?.focus();
  }, []);

  // On a first-run instance there is no account to sign into, send them to signup.
  if (setupRequired) {
    return <Navigate to="/signup" replace state={location.state} />;
  }

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setFormError(null);
    const eErr = validateEmail(email);
    const pErr = validatePassword(password);
    setEmailError(eErr);
    setPasswordError(pErr);
    if (eErr) {
      emailRef.current?.focus();
      return;
    }
    if (pErr) {
      passwordRef.current?.focus();
      return;
    }
    setSubmitting(true);
    try {
      await login(email.trim(), password);
      // Success: RedirectIfAuthenticated navigates away on the phase change.
    } catch (err) {
      // Never differentiate "no such email" from "wrong password".
      if (err instanceof ApiException && (err.status === 400 || err.status === 401)) {
        setFormError("Incorrect email or password.");
      } else {
        setFormError("Couldn't sign in. Please try again.");
      }
      setSubmitting(false);
      passwordRef.current?.focus();
    }
  }

  return (
    <AuthLayout
      title="Sign in"
      subtitle="Sign in to your OpenCaptions account."
      footer={
        registrationEnabled ? (
          <>
            Need an account?{" "}
            <Link to="/signup" className="font-medium text-foreground underline hover:opacity-80">
              Create one
            </Link>
          </>
        ) : null
      }
    >
      <form onSubmit={onSubmit} className="space-y-4" noValidate>
        {formError && (
          <div
            role="alert"
            className="rounded-md border border-destructive/40 bg-destructive/10 p-3 text-sm text-destructive"
          >
            {formError}
          </div>
        )}
        <div>
          <label htmlFor="email" className="mb-1 block text-sm font-medium">
            Email
          </label>
          <input
            ref={emailRef}
            id="email"
            name="email"
            type="email"
            autoComplete="email"
            inputMode="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            aria-invalid={emailError ? true : undefined}
            aria-describedby={emailError ? "email-error" : undefined}
            data-testid="auth-email"
            className="w-full rounded-md border border-border bg-card px-3 py-2 text-sm"
          />
          {emailError && (
            <p id="email-error" role="alert" className="mt-1 text-xs text-destructive">
              {emailError}
            </p>
          )}
        </div>
        <div>
          <label htmlFor="password" className="mb-1 block text-sm font-medium">
            Password
          </label>
          <input
            ref={passwordRef}
            id="password"
            name="password"
            type="password"
            autoComplete="current-password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            aria-invalid={passwordError ? true : undefined}
            aria-describedby={passwordError ? "password-error" : undefined}
            data-testid="auth-password"
            className="w-full rounded-md border border-border bg-card px-3 py-2 text-sm"
          />
          {passwordError && (
            <p id="password-error" role="alert" className="mt-1 text-xs text-destructive">
              {passwordError}
            </p>
          )}
        </div>
        {resetAvailable && (
          <div className="text-right">
            <Link
              to="/forgot-password"
              data-testid="forgot-password-link"
              className="text-sm font-medium text-muted-foreground underline hover:text-foreground"
            >
              Forgot password?
            </Link>
          </div>
        )}
        <button
          type="submit"
          disabled={submitting}
          data-testid="auth-submit"
          className="w-full rounded-md bg-primary text-primary-foreground px-4 py-2 text-sm font-medium hover:opacity-90 disabled:opacity-50"
        >
          {submitting ? "Signing in…" : "Sign in"}
        </button>
      </form>
    </AuthLayout>
  );
}
