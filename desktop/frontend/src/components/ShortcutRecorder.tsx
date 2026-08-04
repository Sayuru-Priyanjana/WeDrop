import { useEffect, useState } from "react";

/** Named keys the phone/desktop already agree on (core/protocol/messages.go's
 * KeyBackspace..KeyF12) — anything else falls through to the literal
 * lowercased character (letters, digits, punctuation). */
const NAMED_KEYS: Record<string, string> = {
  Backspace: "backspace",
  Enter: "enter",
  Tab: "tab",
  Escape: "escape",
  ArrowUp: "up",
  ArrowDown: "down",
  ArrowLeft: "left",
  ArrowRight: "right",
  " ": "space",
  Home: "home",
  End: "end",
  Delete: "delete",
};

const MODIFIER_KEYS = new Set(["Control", "Shift", "Alt", "Meta", "OS"]);

function normalizeKey(e: KeyboardEvent): string {
  if (NAMED_KEYS[e.key]) return NAMED_KEYS[e.key];
  if (/^F(1[0-2]|[1-9])$/.test(e.key)) return e.key.toLowerCase();
  if (e.code === "Backquote") return "`";
  if (e.key.length === 1) return e.key.toLowerCase();
  return e.key.toLowerCase();
}

function displayKey(key: string): string {
  if (!key) return "";
  if (key.length === 1) return key.toUpperCase();
  return key[0].toUpperCase() + key.slice(1);
}

/** Click, then press the actual key combination on the desktop's own
 * keyboard — captured live via a keydown listener while armed, rather than
 * typed as text. This is the single input path for every shortcut in the
 * app: neither the App Actions editor nor the My Buttons editor accepts a
 * hand-typed key name, so what gets saved is always something a real key
 * press produced. */
export function ShortcutRecorder({
  modifiers,
  keyName,
  onChange,
}: {
  modifiers: string[];
  keyName: string;
  onChange: (modifiers: string[], key: string) => void;
}) {
  const [recording, setRecording] = useState(false);

  useEffect(() => {
    if (!recording) return;

    const handleKeyDown = (e: KeyboardEvent) => {
      e.preventDefault();
      e.stopPropagation();
      if (e.key === "Escape") {
        setRecording(false);
        return;
      }
      if (MODIFIER_KEYS.has(e.key)) return; // wait for the real key

      const mods: string[] = [];
      if (e.ctrlKey) mods.push("ctrl");
      if (e.shiftKey) mods.push("shift");
      if (e.altKey) mods.push("alt");
      onChange(mods, normalizeKey(e));
      setRecording(false);
    };

    window.addEventListener("keydown", handleKeyDown, true);
    return () => window.removeEventListener("keydown", handleKeyDown, true);
  }, [recording, onChange]);

  const parts = [...modifiers.map(displayKey), displayKey(keyName)].filter(Boolean);

  return (
    <button
      type="button"
      onClick={() => setRecording(true)}
      onBlur={() => setRecording(false)}
      className={`rounded-xl border px-3 py-1.5 text-[12.5px] font-medium tracking-wide transition-colors ${
        recording
          ? "wd-shimmer border-brand bg-brand/10 text-brand-soft"
          : "border-border bg-black/20 text-ink hover:border-brand/50"
      }`}
    >
      {recording ? "Press keys…" : parts.length > 0 ? parts.join(" + ") : "Click to set"}
    </button>
  );
}
