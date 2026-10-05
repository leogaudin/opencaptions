import { ChevronDown, ChevronUp } from "lucide-react";
import { type ReactNode, useState } from "react";

function readStored(key: string | undefined, fallback: boolean): boolean {
  if (!key) return fallback;
  try {
    const stored = sessionStorage.getItem(key);
    return stored === null ? fallback : stored === "true";
  } catch {
    return fallback;
  }
}

/**
 * A full-width toggle row that reveals `children`. Pass `storageKey` to remember
 * the choice for the session, which then wins over `defaultOpen`.
 */
export function Disclosure({
  label,
  openLabel,
  storageKey,
  defaultOpen = false,
  className,
  children,
}: {
  label: string;
  openLabel: string;
  storageKey?: string;
  defaultOpen?: boolean;
  className?: string;
  children: ReactNode;
}) {
  const [open, setOpen] = useState(() => readStored(storageKey, defaultOpen));

  function toggle() {
    setOpen(!open);
    if (!storageKey) return;
    try {
      sessionStorage.setItem(storageKey, String(!open));
    } catch {
      // Storage unavailable: the choice just is not remembered.
    }
  }

  const Chevron = open ? ChevronUp : ChevronDown;
  return (
    <>
      <button
        type="button"
        onClick={toggle}
        aria-expanded={open}
        className="flex w-full items-center justify-between rounded-md border border-border bg-background px-3 py-2 text-xs font-medium text-muted-foreground hover:bg-accent"
      >
        <span>{open ? openLabel : label}</span>
        <Chevron className="h-3.5 w-3.5" aria-hidden />
      </button>
      {open && <div className={className}>{children}</div>}
    </>
  );
}
