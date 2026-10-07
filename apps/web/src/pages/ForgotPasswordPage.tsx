/**
 * Request a password reset link. Shares layout + validation with the other auth
 * screens.
 *
 * Only reachable when reset is available (SMTP configured); otherwise it bounces
 * to sign in, mirroring how SignupPage bounces when registration is closed. The
 * confirmation is deliberately NEUTRAL: it never reveals whether the email is
 * registered, matching the backend's no-enumeration guarantee.
 */
import { type FormEvent, useEffect, useRef, useState } from "react";
import { Link, Navigate, useLocation } from "react-router-dom";
import { AuthLayout } from "@/components/AuthLayout";
import { requestPasswordReset } from "@/lib/api";
import { validateEmail } from "@/lib/authValidation";
import { useT } from "@/lib/i18n";
import { useAuthStore } from "@/store/authStore";

export function ForgotPasswordPage() {
  const t = useT();
  const resetAvailable = useAuthStore((s) => s.status?.reset_available ?? false);
  const location = useLocation();

  const [email, setEmail] = useState("");
  const [emailError, setEmailError] = useState<string | null>(null);
  const [formError, setFormError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [submitted, setSubmitted] = useState(false);

  const emailRef = useRef<HTMLInputElement>(null);
  useEffect(() => {
    emailRef.current?.focus();
  }, []);

  // Feature off on this instance, there is nowhere to go here. Send to sign in.
  if (!resetAvailable) {
    return <Navigate to="/login" replace state={location.state} />;
  }

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setFormError(null);
    const eErr = validateEmail(email);
    setEmailError(eErr);
    if (eErr) {
      emailRef.current?.focus();
      return;
    }
    setSubmitting(true);
    try {
      await requestPasswordReset(email.trim());
      // Neutral outcome regardless of whether the address is registered.
      setSubmitted(true);
    } catch {
      // A transport/5xx failure is not an existence signal; keep it generic.
      setFormError(t("Couldn't send the reset email. Please try again."));
      setSubmitting(false);
    }
  }

  return (
    <AuthLayout
      title={t("Reset your password")}
      subtitle={
        submitted
          ? undefined
          : "Enter your account email and we'll send a link to set a new password."
      }
      footer={
        <>
          {t("Remembered it?")}{" "}
          <Link to="/login" className="font-medium text-foreground underline hover:opacity-80">
            {t("Back to sign in")}
          </Link>
        </>
      }
    >
      {submitted ? (
        <output
          data-testid="reset-request-sent"
          className="block rounded-md border border-border bg-muted p-3 text-sm text-muted-foreground"
        >
          {t(
            "If an account exists for that email, we've sent a link to set a new password. The link expires in one hour.",
          )}
        </output>
      ) : (
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
          <button
            type="submit"
            disabled={submitting}
            data-testid="auth-submit"
            className="w-full rounded-md bg-primary text-primary-foreground px-4 py-2 text-sm font-medium hover:opacity-90 disabled:opacity-50"
          >
            {submitting ? t("Sending…") : t("Send reset link")}
          </button>
        </form>
      )}
    </AuthLayout>
  );
}
