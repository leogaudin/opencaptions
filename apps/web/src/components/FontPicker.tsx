/**
 * Font picker: the bundled faces, then every Google Fonts family, searchable,
 * each name drawn in its own face. Previews are subsets that can draw only the
 * family's own name, a few KB each, loaded only for the rows on screen.
 */
import * as Dialog from "@radix-ui/react-dialog";
import { ChevronDown, X } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { Field } from "@/components/StyleFields";
import { listFonts } from "@/lib/api";
import { engineFamilies } from "@/lib/engine";
import type { FontFamily } from "@/types";

const SHOWN = 60;

interface Row {
  family: string;
  category: string;
}

const previews = new Map<string, Promise<string | null>>();

/** A CSS font-family that draws `family`'s name in that family, once loaded. */
function previewFace(family: string): Promise<string | null> {
  let face = previews.get(family);
  if (!face) {
    const name = `oc-preview-${family}`;
    const url = `/api/v1/fonts/${encodeURIComponent(family)}/sample`;
    face = new FontFace(name, `url("${url}")`)
      .load()
      .then((f) => {
        document.fonts.add(f);
        return `"${name}"`;
      })
      .catch(() => null);
    previews.set(family, face);
  }
  return face;
}

function FontName({ family }: { family: string }) {
  const [face, setFace] = useState<string | null>(null);
  const ref = useRef<HTMLSpanElement>(null);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    let live = true;
    const seen = new IntersectionObserver(([entry]) => {
      if (!entry?.isIntersecting) return;
      seen.disconnect();
      previewFace(family).then((f) => live && setFace(f));
    });
    seen.observe(el);
    return () => {
      live = false;
      seen.disconnect();
    };
  }, [family]);
  return (
    <span ref={ref} style={face ? { fontFamily: face } : undefined} className="truncate text-base">
      {family}
    </span>
  );
}

export function FontPicker({ value, onChange }: { value: string; onChange: (f: string) => void }) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [rows, setRows] = useState<Row[]>([]);

  useEffect(() => {
    if (!open || rows.length) return;
    Promise.all([
      engineFamilies().catch((): string[] => []),
      listFonts().catch((): FontFamily[] => []),
    ]).then(([bundled, google]) =>
      setRows([
        ...bundled.map((family) => ({ family, category: "Included" })),
        ...google.filter((f) => !bundled.includes(f.family)),
      ]),
    );
  }, [open, rows.length]);

  const q = query.trim().toLowerCase();
  const matches = (q ? rows.filter((r) => r.family.toLowerCase().includes(q)) : rows).slice(
    0,
    SHOWN,
  );

  return (
    <Field label="Font">
      <Dialog.Root open={open} onOpenChange={setOpen}>
        <Dialog.Trigger asChild>
          <button
            type="button"
            className="flex w-full items-center justify-between rounded-md border border-border bg-background px-2 py-1.5 text-xs"
          >
            <FontName family={value} />
            <ChevronDown className="h-3.5 w-3.5 shrink-0 text-muted-foreground" aria-hidden />
          </button>
        </Dialog.Trigger>
        <Dialog.Portal>
          <Dialog.Overlay className="fixed inset-0 z-50 bg-black/50" />
          <Dialog.Content className="fixed left-1/2 top-1/2 z-50 flex max-h-[80vh] w-[90vw] max-w-md -translate-x-1/2 -translate-y-1/2 flex-col rounded-lg border border-border bg-card p-4 shadow-lg focus:outline-hidden">
            <div className="flex items-center justify-between">
              <Dialog.Title className="text-base font-semibold">Font</Dialog.Title>
              <Dialog.Close
                className="text-muted-foreground hover:text-foreground"
                aria-label="Close"
              >
                <X className="h-4 w-4" />
              </Dialog.Close>
            </div>
            <Dialog.Description className="sr-only">
              Search the included fonts and Google Fonts.
            </Dialog.Description>
            <input
              type="search"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder="Search fonts"
              aria-label="Search fonts"
              className="mt-3 w-full rounded-md border border-border bg-background px-2 py-1.5 text-sm"
            />
            <ul className="mt-2 min-h-0 flex-1 overflow-y-auto">
              {matches.map((r) => (
                <li key={r.family}>
                  <button
                    type="button"
                    onClick={() => {
                      onChange(r.family);
                      setOpen(false);
                    }}
                    aria-current={r.family === value}
                    className="flex w-full items-baseline justify-between gap-3 rounded-md px-2 py-1.5 text-left hover:bg-accent aria-[current=true]:bg-accent"
                  >
                    <FontName family={r.family} />
                    <span className="shrink-0 text-[11px] text-muted-foreground">{r.category}</span>
                  </button>
                </li>
              ))}
              {rows.length > 0 && matches.length === 0 && (
                <li className="px-2 py-3 text-sm text-muted-foreground">No font matches.</li>
              )}
            </ul>
          </Dialog.Content>
        </Dialog.Portal>
      </Dialog.Root>
    </Field>
  );
}
