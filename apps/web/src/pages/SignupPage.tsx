/**
 * Signup screen. Shares layout + validation with the login screen.
 *
 * Every account is an ordinary user. With registration off, signup stays open
 * only until the first account exists; after that it redirects to login rather
 * than send the user to an endpoint that will reject them.
 */
import { type FormEvent, useEffect, useRef, useState } from "react";
import { Link, Navigate, useLocation } from "react-router-dom";
import { AuthLayout } from "@/components/AuthLayout";
import { ApiException } from "@/lib/api";
import { MIN_PASSWORD_LENGTH, validateEmail, validatePassword } from "@/lib/authValidation";
import { useT } from "@/lib/i18n";
import { useAuthStore } from "@/store/authStore";
import type { ApiError } from "@/types";

export function SignupPage() {
  const t = useT();
  const register = useAuthStore((s) => s.register);
  // Only redirect when we KNOW registration is closed (status resolved). If the
  // backend was unreachable (status null), render the form and let submit fail
  // visibly rather than bouncing the user around.
  const registrationClosed = useAuthStore(
    (s) => s.status != null && !s.status.setup_required && !s.status.registration_enabled,
  );
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

  if (registrationClosed) {
    return <Navigate to="/login" replace state={location.state} />;
  }

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setFormError(null);
    const eErr = validateEmail(email);
    const pErr = validatePassword(password, { requireStrength: true });
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
      await register(email.trim(), password);
      // Success: RedirectIfAuthenticated navigates away on the phase change.
    } catch (err) {
      if (err instanceof ApiException && err.status === 409) {
        setFormError(t("An account with this email already exists."));
      } else if (err instanceof ApiException && err.status === 400) {
        setFormError(
          (err.body as ApiError | null)?.detail ?? "Please check your details and try again.",
        );
      } else {
        setFormError(t("Couldn't create your account. Please try again."));
      }
      setSubmitting(false);
    }
  }

  return (
    <AuthLayout
      title={t("Create your account")}
      subtitle={t("Sign up to start captioning your videos.")}
      footer={
        <>
          {t("Already have an account?")}{" "}
          <Link to="/login" className="font-medium text-foreground underline hover:opacity-80">
            {t("Sign in")}
          </Link>
        </>
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
            {t("Email")}
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
            {t("Password")}
          </label>
          <input
            ref={passwordRef}
            id="password"
            name="password"
            type="password"
            autoComplete="new-password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            aria-invalid={passwordError ? true : undefined}
            aria-describedby={passwordError ? "password-error" : "password-hint"}
            data-testid="auth-password"
            className="w-full rounded-md border border-border bg-card px-3 py-2 text-sm"
          />
          {passwordError ? (
            <p id="password-error" role="alert" className="mt-1 text-xs text-destructive">
              {passwordError}
            </p>
          ) : (
            <p id="password-hint" className="mt-1 text-xs text-muted-foreground">
              {t("At least {n} characters.", { n: MIN_PASSWORD_LENGTH })}
            </p>
          )}
        </div>
        <button
          type="submit"
          disabled={submitting}
          data-testid="auth-submit"
          className="w-full rounded-md bg-primary text-primary-foreground px-4 py-2 text-sm font-medium hover:opacity-90 disabled:opacity-50"
        >
          {submitting ? t("Creating account…") : t("Create account")}
        </button>
      </form>
    </AuthLayout>
  );
}
