/**
 * API keys on the Account page: mint one for a script, see each key's prefix and
 * when it was last used, revoke it. A new key is shown once, with a request to
 * copy and an example call, because it cannot be shown again.
 */
import { Check, Copy, KeyRound, Trash2 } from "lucide-react";
import qrcode from "qrcode-generator";
import { type FormEvent, useEffect, useMemo, useState } from "react";
import * as api from "@/lib/api";
import { useT } from "@/lib/i18n";
import type { ApiKey } from "@/types";

const DOCS = "/api/v1/docs";

export function ApiKeys() {
  const t = useT();
  const [keys, setKeys] = useState<ApiKey[]>([]);
  const [name, setName] = useState("");
  const [created, setCreated] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    api.listApiKeys().then(setKeys, () => setError(t("Could not load keys.")));
  }, [t]);

  async function create(e: FormEvent): Promise<void> {
    e.preventDefault();
    setError(null);
    try {
      const key = await api.createApiKey(name.trim());
      setCreated(key.key);
      setName("");
      setKeys([key, ...keys]);
    } catch {
      setError(t("Could not create the key."));
    }
  }

  async function revoke(key: ApiKey): Promise<void> {
    // Irreversible, and breaks any script still using the key.
    if (
      !window.confirm(t("Revoke “{name}”? Scripts using it will stop working.", { name: key.name }))
    )
      return;
    const id = key.id;
    await api.revokeApiKey(id).then(
      () => setKeys(keys.filter((k) => k.id !== id)),
      () => setError(t("Could not revoke the key.")),
    );
  }

  return (
    <section className="mt-8 rounded-lg border border-border bg-card p-4" data-testid="api-keys">
      <h2 className="text-sm font-semibold">{t("API keys")}</h2>
      <p className="mt-1 text-xs text-muted-foreground">
        Call the API from scripts with <code>Authorization: Bearer &lt;key&gt;</code>. Every
        endpoint is documented, and can be tried, in the{" "}
        <a href={DOCS} target="_blank" rel="noreferrer" className="underline">
          {t("API reference")}
        </a>
        .
      </p>

      {created && <NewKey value={created} onDone={() => setCreated(null)} />}

      <form className="mt-3 flex gap-2" onSubmit={create}>
        <input
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder={t("Name, e.g. podcast pipeline")}
          aria-label={t("Key name")}
          maxLength={100}
          required
          className="min-w-0 flex-1 rounded-md border border-border bg-background px-2 py-1.5 text-sm"
        />
        <button
          type="submit"
          className="inline-flex items-center gap-1.5 rounded-md bg-primary px-3 py-1.5 text-sm font-medium text-primary-foreground hover:bg-primary/90"
        >
          <KeyRound className="h-3.5 w-3.5" aria-hidden />
          {t("Create key")}
        </button>
      </form>
      {error && (
        <p className="mt-2 text-xs text-destructive" role="alert">
          {error}
        </p>
      )}

      {keys.length > 0 && (
        <ul className="mt-3 divide-y divide-border text-sm">
          {keys.map((k) => (
            <li key={k.id} className="flex items-center justify-between gap-3 py-2">
              <div className="min-w-0">
                <p className="truncate font-medium">{k.name}</p>
                <p className="text-[11px] text-muted-foreground">
                  <code>{k.prefix}…</code> · {t("created {day}", { day: day(k.created_at) })} ·{" "}
                  {k.last_used_at
                    ? t("last used {day}", { day: day(k.last_used_at) })
                    : t("never used")}
                </p>
              </div>
              <button
                type="button"
                onClick={() => revoke(k)}
                aria-label={t("Revoke {name}", { name: k.name })}
                title={t("Revoke")}
                className="inline-flex h-7 w-7 shrink-0 items-center justify-center rounded-md border border-border text-muted-foreground hover:bg-accent hover:text-destructive"
              >
                <Trash2 className="h-3.5 w-3.5" aria-hidden />
              </button>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

function NewKey({ value, onDone }: { value: string; onDone: () => void }) {
  const t = useT();
  const [copied, setCopied] = useState(false);
  const example = `curl -H "Authorization: Bearer ${value}" ${location.origin}/api/v1/projects`;
  // Opens the OpenCaptions app on a phone and fills in this server and key. The phone has to
  // reach the address, so a page opened as localhost is called out.
  const pairing = `opencaptions://connect?url=${encodeURIComponent(location.origin)}&key=${encodeURIComponent(value)}`;
  const local = ["localhost", "127.0.0.1", "::1", "[::1]"].includes(location.hostname);
  // The same link as a QR code: the phone's own Camera app reads it and offers to open OpenCaptions,
  // so nothing has to be sent between the computer and the phone.
  const qr = useMemo(() => {
    const code = qrcode(0, "M");
    code.addData(pairing);
    code.make();
    return code.createDataURL(6, 2);
  }, [pairing]);
  return (
    <div
      className="mt-3 rounded-md border border-amber-500/40 bg-amber-500/10 p-3 text-xs"
      role="status"
      data-testid="new-api-key"
    >
      <p className="font-medium text-foreground">
        {t("Copy this key now. It will not be shown again.")}
      </p>
      <div className="mt-2 flex items-center gap-2">
        <code className="min-w-0 flex-1 truncate rounded bg-background px-2 py-1">{value}</code>
        <button
          type="button"
          onClick={() =>
            navigator.clipboard.writeText(value).then(
              () => setCopied(true),
              () => undefined,
            )
          }
          aria-label={t("Copy key")}
          className="inline-flex h-7 w-7 items-center justify-center rounded-md border border-border hover:bg-accent"
        >
          {copied ? <Check className="h-3.5 w-3.5" /> : <Copy className="h-3.5 w-3.5" />}
        </button>
      </div>
      <pre className="mt-2 overflow-x-auto rounded bg-background p-2 text-[11px]">{example}</pre>
      <p className="mt-3 font-medium text-foreground">{t("Use it from the OpenCaptions app")}</p>
      <p className="mt-1 text-muted-foreground">
        {t(
          "Open this link on the phone (send it by message or AirDrop) to transcribe on this server instead of on the phone.",
        )}
        {local &&
          " This page is open as localhost, which a phone cannot reach: open this page by this computer's address on your network, then create the key."}
      </p>
      <div className="mt-2 flex items-start gap-3">
        <img
          src={qr}
          alt={t("QR code that connects the OpenCaptions app to this server")}
          data-testid="pairing-qr"
          className="h-36 w-36 shrink-0 rounded-md bg-white p-1"
          style={{ imageRendering: "pixelated" }}
        />
        <div className="min-w-0">
          <p className="text-muted-foreground">
            {t("Or point the phone's Camera at this code and tap the banner that appears.")}
          </p>
          <code className="mt-1 block break-all rounded bg-background px-2 py-1 text-[11px]">
            {pairing}
          </code>
        </div>
      </div>
      <button type="button" onClick={onDone} className="mt-2 underline">
        {t("Done")}
      </button>
    </div>
  );
}

const day = (iso: string) => new Date(iso).toLocaleDateString();
