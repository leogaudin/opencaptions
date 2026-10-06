/**
 * The remote OpenCaptions instance this server is set to transcribe on, with a button that
 * tries it: reachable, key accepted, a version it can talk to. Shown only when one is
 * configured (TRANSCRIPTION_REMOTE_URL and _KEY), since that is deployment configuration.
 */
import { useState } from "react";
import * as api from "@/lib/api";
import { useTranscriptionSettings } from "@/lib/useTranscriptionSettings";

export function TranscriptionService() {
  const { settings } = useTranscriptionSettings();
  const [result, setResult] = useState<api.RemoteTranscriptionTest | null>(null);
  const [testing, setTesting] = useState(false);
  const remote = settings?.transcription;
  if (!remote?.remote_configured || !remote.remote_url) return null;

  async function test(): Promise<void> {
    setTesting(true);
    setResult(null);
    try {
      setResult(await api.testRemoteTranscription());
    } catch {
      setResult({ ok: false, error: "The test could not be run." });
    } finally {
      setTesting(false);
    }
  }

  return (
    <section
      className="mt-8 rounded-lg border border-border bg-card p-4"
      data-testid="transcription-service"
    >
      <h2 className="text-sm font-semibold">Transcription service</h2>
      <p className="mt-1 text-xs text-muted-foreground">
        This server can send audio to another OpenCaptions server to be transcribed:{" "}
        <code>{remote.remote_url}</code>. Choose it when you add a video. It is set with{" "}
        <code>TRANSCRIPTION_REMOTE_URL</code> and <code>TRANSCRIPTION_REMOTE_KEY</code>.
      </p>
      <button
        type="button"
        onClick={test}
        disabled={testing}
        className="mt-3 rounded-md border border-border px-3 py-1.5 text-sm font-medium hover:bg-accent disabled:opacity-50"
      >
        {testing ? "Testing…" : "Test connection"}
      </button>
      {result?.ok === true && (
        <p className="mt-2 text-xs text-foreground" role="status" data-testid="remote-test-ok">
          Connected to {result.instance_name ?? "the remote server"}. It offers{" "}
          {result.models.length > 0
            ? result.models.map((m) => m.label).join(", ")
            : "its own model"}
          .
        </p>
      )}
      {result?.ok === false && (
        <p className="mt-2 text-xs text-destructive" role="alert" data-testid="remote-test-error">
          {result.error}
        </p>
      )}
    </section>
  );
}
