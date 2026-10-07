/**
 * Set a new password from a reset link. Shares layout + validation with the
 * other auth screens.
 *
 * The token arrives in the URL query and is used ONLY in memory for the submit,
 * never written to localStorage (nor is the password). Only reachable when reset
 * is available (SMTP configured). On success the server has already revoked
 * every existing session and creates no new one, so we send the user to sign in.
 */
import { type FormEvent, useEffect, useRef, useState } from "react";
import { Link, Navigate, useNavigate, useSearchParams } from "react-router-dom";
import { AuthLayout } from "@/components/AuthLayout";
import { ApiException, confirmPasswordReset } from "@/lib/api";
import { MIN_PASSWORD_LENGTH, validatePassword } from "@/lib/authValidation";
import { useT } from "@/lib/i18n";
import { useAuthStore } from "@/store/authStore";

export function ResetPasswordPage() {
  const t = useT();
  const resetAvailable = useAuthStore((s) => s.status?.reset_available ?? false);
  const [searchParams] = useSearchParams();
  const navigate = useNavigate();
  const token = searchParams.get("token") ?? "";

  const [password, setPassword] = useState("");
  const [passwordError, setPasswordError] = useState<string | null>(null);
  const [formError, setFormError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  const passwordRef = useRef<HTMLInputElement>(null);
  useEffect(() => {
    passwordRef.current?.focus();
  }, []);

  // Feature off on this instance, nowhere to go here. Send to sign in.
  if (!resetAvailable) {
    return <Navigate to="/login" replace />;
  }

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setFormError(null);
    const pErr = validatePassword(password, { requireStrength: true });
    setPasswordError(pErr);
    if (pErr) {
      passwordRef.current?.focus();
      return;
    }
    setSubmitting(true);
    try {
      await confirmPasswordReset(token, password);
      // Success: every old session is dead and no new one was created. Send the
      // user to sign in with the new password.
      navigate("/login", { replace: true });
    } catch (err) {
      if (err instanceof ApiException && (err.status === 400 || err.status === 422)) {
        setFormError(
          t("This reset link is invalid or has expired. Request a new one to try again."),
        );
      } else {
        setFormError(t("Couldn't reset your password. Please try again."));
      }
      setSubmitting(false);
      passwordRef.current?.focus();
    }
  }

  return (
    <AuthLayout
      title={t("Choose a new password")}
      subtitle={t("Enter a new password for your OpenCaptions account.")}
      footer={
        <>
          {t("Need a new link?")}{" "}
          <Link
            to="/forgot-password"
            className="font-medium text-foreground underline hover:opacity-80"
          >
            {t("Request another")}
          </Link>
        </>
      }
    >
      {token ? (
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
            <label htmlFor="password" className="mb-1 block text-sm font-medium">
              {t("New password")}
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
            {submitting ? t("Saving…") : t("Set new password")}
          </button>
        </form>
      ) : (
        <div
          role="alert"
          data-testid="reset-missing-token"
          className="rounded-md border border-destructive/40 bg-destructive/10 p-3 text-sm text-destructive"
        >
          {t(
            "This reset link is missing its token. Please open the link from your email again, or",
          )}{" "}
          <Link to="/forgot-password" className="font-medium underline hover:opacity-80">
            {t("request a new one")}
          </Link>
          .
        </div>
      )}
    </AuthLayout>
  );
}
