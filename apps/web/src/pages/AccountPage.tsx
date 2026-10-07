/**
 * AccountPage: what this account is, what it has used, how to change it, and
 * the keys it calls the API with.
 *
 * Usage is shown because it is what a hosted plan would meter, so a self-hoster
 * sees the same numbers their bill would be built from.
 */
import { type FormEvent, type ReactNode, useEffect, useState } from "react";
import { ApiKeys } from "@/components/ApiKeys";
import { TranscriptionService } from "@/components/TranscriptionService";
import * as api from "@/lib/api";
import { MIN_PASSWORD_LENGTH } from "@/lib/authValidation";
import { useT } from "@/lib/i18n";
import { useAuthStore } from "@/store/authStore";
import type { UsageRead } from "@/types";
import type { AuthUser } from "@/types/auth";

export function AccountPage() {
  const t = useT();
  const user = useAuthStore((s) => s.user);
  const setUser = useAuthStore((s) => s.setUser);
  const [usage, setUsage] = useState<UsageRead | null>(null);

  useEffect(() => {
    let cancelled = false;
    api
      .getMyUsage()
      .then((u) => !cancelled && setUsage(u))
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, []);

  return (
    <div className="container mx-auto max-w-2xl px-4 py-10">
      <h1 className="text-2xl font-semibold">{t("Account")}</h1>
      <p className="mt-1 text-sm text-muted-foreground">{user?.email}</p>

      <section className="mt-8">
        <h2 className="text-sm font-semibold">{t("Usage")}</h2>
        <p className="mt-1 text-xs text-muted-foreground">
          {t("Totalled from completed jobs. This instance does not meter or limit it.")}
        </p>
        <dl className="mt-3 grid grid-cols-3 gap-3" data-testid="usage">
          <Stat
            label={t("Transcribed")}
            value={usage ? formatSeconds(usage.transcription_seconds) : "-"}
          />
          <Stat
            label={t("Frames rendered")}
            value={usage ? usage.render_frames.toLocaleString() : "-"}
          />
          <Stat label={t("Projects")} value={usage ? String(usage.projects) : "-"} />
        </dl>
      </section>

      <ChangeEmailForm currentEmail={user?.email ?? ""} onChanged={(u) => setUser(u)} />
      <ChangePasswordForm />
      <TranscriptionService />
      <ApiKeys />
    </div>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-lg border border-border bg-card p-3">
      <dt className="text-[11px] uppercase tracking-wide text-muted-foreground">{label}</dt>
      <dd className="mt-1 text-lg font-semibold tabular-nums">{value}</dd>
    </div>
  );
}

function ChangeEmailForm({
  currentEmail,
  onChanged,
}: {
  currentEmail: string;
  onChanged: (user: AuthUser) => void;
}) {
  const t = useT();
  const [email, setEmail] = useState(currentEmail);
  const [password, setPassword] = useState("");
  const [state, setState] = useState<FormState>({ kind: "idle" });

  async function submit(e: FormEvent) {
    e.preventDefault();
    setState({ kind: "busy" });
    try {
      const updated = await api.changeEmail(email.trim(), password);
      onChanged(updated);
      setPassword("");
      setState({ kind: "done", message: "Email updated." });
    } catch (err) {
      setState({ kind: "error", message: messageFor(err) });
    }
  }

  return (
    <Section title={t("Email")} onSubmit={submit} state={state} submitLabel="Update email">
      <Field label={t("New email")} htmlFor="account-email">
        <input
          id="account-email"
          type="email"
          required
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          className={inputClass}
        />
      </Field>
      <Field label={t("Current password")} htmlFor="account-email-password">
        <input
          id="account-email-password"
          type="password"
          required
          autoComplete="current-password"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          className={inputClass}
        />
      </Field>
    </Section>
  );
}

function ChangePasswordForm() {
  const t = useT();
  const [current, setCurrent] = useState("");
  const [next, setNext] = useState("");
  const [state, setState] = useState<FormState>({ kind: "idle" });

  async function submit(e: FormEvent) {
    e.preventDefault();
    setState({ kind: "busy" });
    try {
      await api.changePassword(current, next);
      setCurrent("");
      setNext("");
      setState({
        kind: "done",
        message: "Password updated. Other devices have been signed out.",
      });
    } catch (err) {
      setState({ kind: "error", message: messageFor(err) });
    }
  }

  return (
    <Section title={t("Password")} onSubmit={submit} state={state} submitLabel="Update password">
      <Field label={t("Current password")} htmlFor="account-current">
        <input
          id="account-current"
          type="password"
          required
          autoComplete="current-password"
          value={current}
          onChange={(e) => setCurrent(e.target.value)}
          className={inputClass}
        />
      </Field>
      <Field label={t("New password")} htmlFor="account-next">
        <input
          id="account-next"
          type="password"
          required
          minLength={8}
          autoComplete="new-password"
          value={next}
          onChange={(e) => setNext(e.target.value)}
          className={inputClass}
        />
        <p className="mt-1 text-[11px] text-muted-foreground">
          {t("At least {n} characters.", { n: MIN_PASSWORD_LENGTH })}
        </p>
      </Field>
    </Section>
  );
}

type FormState =
  | { kind: "idle" }
  | { kind: "busy" }
  | { kind: "done"; message: string }
  | { kind: "error"; message: string };

const inputClass =
  "w-full rounded-md border border-border bg-background px-3 py-2 text-sm outline-hidden focus-visible:ring-2 focus-visible:ring-ring";

/** Turn an ApiException into something worth reading, not a status code. */
function messageFor(err: unknown): string {
  if (err instanceof api.ApiException) {
    const code = err.body?.error;
    if (code === "invalid_credentials") return "That password is not correct.";
    if (code === "email_taken") return "That email is already registered.";
    return err.body?.detail || "Something went wrong.";
  }
  return "Something went wrong.";
}

function Field({
  label,
  htmlFor,
  children,
}: {
  label: string;
  htmlFor: string;
  children: ReactNode;
}) {
  return (
    <div>
      <label className="mb-1 block text-xs font-medium" htmlFor={htmlFor}>
        {label}
      </label>
      {children}
    </div>
  );
}

function Section({
  title,
  submitLabel,
  state,
  onSubmit,
  children,
}: {
  title: string;
  submitLabel: string;
  state: FormState;
  onSubmit: (e: FormEvent) => void;
  children: ReactNode;
}) {
  return (
    <section className="mt-8 rounded-lg border border-border bg-card p-4">
      <h2 className="text-sm font-semibold">{title}</h2>
      <form className="mt-3 space-y-3" onSubmit={onSubmit}>
        {children}
        <div className="flex items-center gap-3">
          <button
            type="submit"
            disabled={state.kind === "busy"}
            className="rounded-md bg-primary px-3 py-2 text-sm font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
          >
            {state.kind === "busy" ? "Saving…" : submitLabel}
          </button>
          {state.kind === "error" && (
            <span className="text-xs text-destructive" role="alert">
              {state.message}
            </span>
          )}
          {state.kind === "done" && (
            <span className="text-xs text-green-500" role="status">
              {state.message}
            </span>
          )}
        </div>
      </form>
    </section>
  );
}

/** Seconds as a human duration: the transcription total is often hours. */
function formatSeconds(total: number): string {
  const seconds = Math.round(total);
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  if (hours) return `${hours}h ${minutes}m`;
  if (minutes) return `${minutes}m ${seconds % 60}s`;
  return `${seconds}s`;
}
