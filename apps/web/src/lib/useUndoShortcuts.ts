import { useEffect } from "react";
import { typing } from "@/lib/keyboard";
import { useEditorStore } from "@/store/editorStore";

/**
 * Ctrl/⌘+Z undoes the last caption edit, Shift+Ctrl/⌘+Z (or Ctrl+Y) redoes it. A text field
 * keeps its own undo, and a dialog owns its keys.
 */
export function useUndoShortcuts(): void {
  useEffect(() => {
    const onKey = (e: KeyboardEvent): void => {
      if (e.defaultPrevented || e.altKey || !(e.ctrlKey || e.metaKey) || typing(e.target)) return;
      if (e.target instanceof HTMLElement && e.target.closest("[role=dialog], [role=menu]")) return;
      const { undo, redo } = useEditorStore.getState();
      const key = e.key.toLowerCase();
      if (key === "z") {
        e.preventDefault();
        if (e.shiftKey) redo();
        else undo();
      } else if (key === "y" && !e.metaKey) {
        e.preventDefault();
        redo();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);
}
