import { useState } from "react";
import { useEditorStore } from "@/store/editorStore";
import type { Transcript } from "@/types";

/** Every segment with its timing; click a word to edit it. */
export function TranscriptSegments({ transcript }: { transcript: Transcript }) {
  const updateWord = useEditorStore((s) => s.updateWord);
  const removeWord = useEditorStore((s) => s.removeWord);
  return (
    <div className="mt-3 max-h-[480px] space-y-2 overflow-y-auto pr-1 text-sm">
      {transcript.segments.map((seg) => (
        <div
          key={seg.id}
          className="rounded-md border border-transparent bg-background/40 p-2 transition-colors hover:border-border/60"
        >
          <div className="mb-1 text-[11px] tabular-nums text-muted-foreground">
            {seg.start.toFixed(2)}s → {seg.end.toFixed(2)}s
          </div>
          <div className="flex flex-wrap items-center gap-1">
            {seg.words.map((w, i) => (
              <EditableWord
                // biome-ignore lint/suspicious/noArrayIndexKey: words have no stable id
                key={i}
                text={w.text}
                onCommit={(text) => (text ? updateWord(seg.id, i, text) : removeWord(seg.id, i))}
              />
            ))}
          </div>
        </div>
      ))}
    </div>
  );
}

/** Click to edit. Clearing the text deletes the word, which is how one is removed. */
function EditableWord({ text, onCommit }: { text: string; onCommit: (newText: string) => void }) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(text);

  if (editing) {
    return (
      <input
        type="text"
        // biome-ignore lint/a11y/noAutofocus: inline edit input must focus immediately on activation
        autoFocus
        value={draft}
        onChange={(e) => setDraft(e.target.value)}
        onBlur={() => {
          const next = draft.trim();
          if (next !== text) onCommit(next);
          setEditing(false);
        }}
        onKeyDown={(e) => {
          if (e.key === "Enter") {
            e.currentTarget.blur();
          } else if (e.key === "Escape") {
            setDraft(text);
            setEditing(false);
          }
        }}
        className="rounded bg-primary/10 px-1 text-sm outline-hidden ring-1 ring-primary"
        size={Math.max(2, draft.length)}
      />
    );
  }
  return (
    <button
      type="button"
      onClick={() => {
        setDraft(text);
        setEditing(true);
      }}
      title="Edit, or clear the text to delete"
      className="rounded px-1 text-sm transition-colors hover:bg-accent hover:ring-1 hover:ring-border"
    >
      {text}
    </button>
  );
}
