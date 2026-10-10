/**
 * The transcript as text: every word, its start and end, and which segment it sits in, for
 * edits the editor has no control for yet (splitting or merging segments, retiming many
 * words, fixing a run of them). It is also where a subtitle file (SRT, WebVTT, or our JSON)
 * is imported: the file is turned into the same text, to look over before it is applied.
 *
 * Applying replaces the transcript as one undo step. The format and its checks are
 * `lib/transcriptText`; this is the dialog around them.
 */
import * as Dialog from "@radix-ui/react-dialog";
import { Braces, FileInput, X } from "lucide-react";
import { useMemo, useRef, useState } from "react";
import { useT } from "@/lib/i18n";
import {
  formatTranscript,
  highlight,
  importSubtitles,
  type Parsed,
  parseTranscript,
  type TextError,
} from "@/lib/transcriptText";
import { useEditorStore } from "@/store/editorStore";

/** Subtitle files read as text; the picker offers these. */
const ACCEPT = ".srt,.vtt,.json,application/x-subrip,text/vtt,application/json";

/** Shared by the textarea and the coloured copy under it, so the two line up letter for letter. */
const EDITOR_TEXT = "m-0 whitespace-pre p-3 font-mono text-xs leading-5";
const TOKEN_CLASS = {
  key: "text-sky-700 dark:text-sky-300",
  string: "text-emerald-700 dark:text-emerald-300",
  number: "text-amber-700 dark:text-amber-300",
  punctuation: "text-muted-foreground",
  plain: "text-foreground",
} as const;

export function TranscriptTextDialog() {
  const t = useT();
  const transcript = useEditorStore((s) => s.transcript);
  const replaceTranscript = useEditorStore((s) => s.replaceTranscript);
  const [open, setOpen] = useState(false);
  const [text, setText] = useState("");
  const [original, setOriginal] = useState("");
  const [importError, setImportError] = useState<TextError | null>(null);
  const picker = useRef<HTMLInputElement>(null);
  const colours = useRef<HTMLPreElement>(null);

  const parsed: Parsed | null = useMemo(
    () => (transcript && open ? parseTranscript(text, transcript) : null),
    [text, transcript, open],
  );
  const error: TextError | null = importError ?? (parsed && !parsed.ok ? parsed : null);

  function onOpenChange(next: boolean): void {
    if (next && transcript) {
      const shown = formatTranscript(transcript);
      setText(shown);
      setOriginal(shown);
      setImportError(null);
    }
    setOpen(next);
  }

  async function readFile(file: File | undefined): Promise<void> {
    if (!file || !transcript) return;
    const result = importSubtitles(await file.text(), transcript);
    if (result.ok) {
      setText(formatTranscript(result.transcript));
      setImportError(null);
    } else {
      setImportError(result);
    }
  }

  function apply(): void {
    if (parsed?.ok) replaceTranscript(parsed.transcript);
    setOpen(false);
  }

  function describe(e: TextError): string {
    switch (e.code) {
      case "json":
        return t("Not valid JSON: {message}", { message: e.message });
      case "shape":
        return t("The text must be an object with a list of segments, each with a list of words.");
      case "word":
        return t(
          "Segment {segment}, word {word}: a word needs text, and a start and an end in seconds with the end not before the start.",
          { segment: e.segment, word: e.word },
        );
      case "order":
        return t("Segment {segment}, word {word}: starts before the word that comes before it.", {
          segment: e.segment,
          word: e.word,
        });
      case "empty":
        return t("There are no words in it.");
      case "format":
        return t("That file is not SRT, WebVTT or an OpenCaptions JSON export.");
    }
  }

  if (!transcript) return null;
  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Trigger asChild>
        <button
          type="button"
          data-testid="transcript-text-open"
          className="inline-flex items-center gap-1.5 rounded-full bg-muted px-3 py-1.5 text-xs font-semibold text-foreground hover:bg-muted/70"
        >
          <Braces className="h-3.5 w-3.5" aria-hidden />
          {t("Edit JSON")}
        </button>
      </Dialog.Trigger>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-50 bg-black/50" />
        <Dialog.Content
          data-testid="transcript-text-dialog"
          className="fixed left-1/2 top-1/2 z-50 flex max-h-[90vh] w-[94vw] max-w-3xl -translate-x-1/2 -translate-y-1/2 flex-col gap-3 rounded-lg border border-border bg-card p-5 shadow-lg focus:outline-hidden"
        >
          <div className="flex items-center justify-between">
            <Dialog.Title className="text-base font-semibold">
              {t("Edit transcript as text")}
            </Dialog.Title>
            <Dialog.Close
              className="text-muted-foreground hover:text-foreground"
              aria-label={t("Close")}
            >
              <X className="h-4 w-4" />
            </Dialog.Close>
          </div>
          <Dialog.Description className="text-xs text-muted-foreground">
            {t(
              "One word to a line. Change a word, its start or its end (in seconds), or move words between segments, then apply. Applying can be undone.",
            )}
          </Dialog.Description>

          <div className="relative h-[55vh] min-h-40 rounded-md border border-border bg-background focus-within:ring-2 focus-within:ring-primary">
            {/* The text drawn in colour sits under a transparent textarea that does the editing. */}
            <pre
              ref={colours}
              aria-hidden
              className={`${EDITOR_TEXT} pointer-events-none absolute inset-0 overflow-hidden`}
            >
              {highlight(text).map((token, i) => (
                // biome-ignore lint/suspicious/noArrayIndexKey: the pieces are redrawn whole
                <span key={i} className={TOKEN_CLASS[token.kind]}>
                  {token.text}
                </span>
              ))}
              {"\n "}
            </pre>
            <textarea
              data-testid="transcript-text"
              aria-label={t("Transcript text")}
              value={text}
              onChange={(e) => {
                setText(e.target.value);
                setImportError(null);
              }}
              onScroll={(e) => {
                if (!colours.current) return;
                colours.current.scrollTop = e.currentTarget.scrollTop;
                colours.current.scrollLeft = e.currentTarget.scrollLeft;
              }}
              spellCheck={false}
              wrap="off"
              className={`${EDITOR_TEXT} absolute inset-0 resize-none overflow-auto bg-transparent text-transparent caret-foreground focus:outline-hidden`}
            />
          </div>

          <p
            data-testid="transcript-text-status"
            role={error ? "alert" : undefined}
            className={`min-h-4 text-xs ${error ? "text-destructive" : "text-muted-foreground"}`}
          >
            {error
              ? describe(error)
              : parsed?.ok
                ? t("{words} words in {segments} segments", {
                    words: parsed.words,
                    segments: parsed.transcript.segments.length,
                  })
                : ""}
          </p>

          <div className="flex flex-wrap items-center justify-between gap-2">
            <button
              type="button"
              data-testid="transcript-import"
              onClick={() => picker.current?.click()}
              className="inline-flex items-center gap-1.5 rounded-md border border-border px-3 py-1.5 text-xs hover:bg-accent"
            >
              <FileInput className="h-3.5 w-3.5" aria-hidden />
              {t("Import subtitles…")}
            </button>
            <input
              ref={picker}
              type="file"
              accept={ACCEPT}
              hidden
              data-testid="transcript-import-file"
              onChange={(e) => {
                readFile(e.target.files?.[0]);
                // The same file chosen twice should still be read twice.
                e.target.value = "";
              }}
            />
            <div className="flex gap-2">
              <Dialog.Close className="rounded-md border border-border px-3 py-1.5 text-xs hover:bg-accent">
                {t("Cancel")}
              </Dialog.Close>
              <button
                type="button"
                data-testid="transcript-text-apply"
                onClick={apply}
                disabled={!parsed?.ok || text === original}
                className="rounded-md bg-primary px-3 py-1.5 text-xs font-semibold text-primary-foreground hover:opacity-90 disabled:opacity-50"
              >
                {t("Apply")}
              </button>
            </div>
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
