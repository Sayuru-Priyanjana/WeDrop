import { useEffect, useState } from "react";
import { protocol } from "../../wailsjs/go/models";
import { Button, Card, IconButton, SectionTitle } from "./ui";
import { ShortcutRecorder } from "./ShortcutRecorder";
import { IconPlus, IconTrash } from "../lib/icons";

const ICON_KEYS = [
  "bolt", "terminal", "code", "folder", "globe", "apps", "keyboard", "save",
  "search", "refresh", "star", "settings", "music", "camera", "mail", "chat",
  "lock", "power", "link", "file", "download", "upload", "play", "brush",
  "build", "database", "cloud", "home", "calendar", "note", "calculate",
  "timer", "rocket", "shield", "bug", "monitor", "grid", "undo", "redo",
  "git", "run", "debug", "back", "forward", "copy", "paste", "cut",
  "selectall", "close",
];

const PALETTE = [
  "#4F7CFF", "#9B6BFF", "#2FCE8F", "#F2B544", "#F2555A",
  "#29B6D8", "#FF8A5C", "#B868E0",
];

const ACTION_TYPES: { value: string; label: string }[] = [
  { value: "shortcut", label: "Keyboard shortcut" },
  { value: "open_app", label: "Open application" },
  { value: "open_folder", label: "Open folder" },
  { value: "open_url", label: "Open website" },
  { value: "shell_command", label: "Shell command" },
];

const inputClass =
  "w-full rounded-xl border border-border bg-bg-soft px-3 py-1.5 text-[13px] text-ink outline-none transition-colors focus:border-brand";

interface WorkspaceActionDraft {
  type: string;
  action: string;
  modifiers?: string[];
  key?: string;
  path?: string;
  url?: string;
  command?: string;
}
interface ButtonDraft {
  id: string;
  label: string;
  icon: string;
  color_value: number;
  action: WorkspaceActionDraft;
}

function newButton(): ButtonDraft {
  return {
    id: `custom-${Date.now()}`,
    label: "New button",
    icon: "bolt",
    color_value: 0,
    action: { type: "workspace_action", action: "shortcut", modifiers: ["ctrl"], key: "" },
  };
}

export function MyButtonsPanel({
  onLoad,
  onSave,
}: {
  onLoad: () => Promise<protocol.WorkspaceButtonDef[]>;
  onSave: (buttons: protocol.WorkspaceButtonDef[]) => Promise<void>;
}) {
  const [draft, setDraft] = useState<ButtonDraft[] | null>(null);
  const [dirty, setDirty] = useState(false);

  useEffect(() => {
    onLoad().then((buttons) => {
      setDraft((buttons ?? []).map((b) => ({ ...b, action: { ...b.action } })));
      setDirty(false);
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const update = (fn: (d: ButtonDraft[]) => ButtonDraft[]) => {
    setDraft((current) => (current ? fn(current) : current));
    setDirty(true);
  };

  const handleSave = async () => {
    if (!draft) return;
    await onSave(draft.map((b) => protocol.WorkspaceButtonDef.createFrom(b)));
    setDirty(false);
  };

  if (!draft) return null;

  return (
    <div>
      <SectionTitle
        title="My Buttons"
        hint="Shown on every paired phone's Widgets tab, read-only there."
        action={
          <Button variant="primary" onClick={handleSave} disabled={!dirty}>
            Save changes
          </Button>
        }
      />

      <div className="max-w-2xl space-y-3">
        {draft.map((button, i) => (
          <ButtonRow
            key={button.id}
            button={button}
            onChange={(next) => update((d) => d.map((b, j) => (j === i ? next : b)))}
            onRemove={() => update((d) => d.filter((_, j) => j !== i))}
            onMove={(delta) =>
              update((d) => {
                const j = i + delta;
                if (j < 0 || j >= d.length) return d;
                const copy = [...d];
                [copy[i], copy[j]] = [copy[j], copy[i]];
                return copy;
              })
            }
          />
        ))}
      </div>

      <Button variant="ghost" className="mt-3" onClick={() => update((d) => [...d, newButton()])}>
        <IconPlus className="h-4 w-4" />
        Add button
      </Button>
    </div>
  );
}

function ButtonRow({
  button,
  onChange,
  onRemove,
  onMove,
}: {
  button: ButtonDraft;
  onChange: (next: ButtonDraft) => void;
  onRemove: () => void;
  onMove: (delta: number) => void;
}) {
  const wsAction = button.action;
  const actionType = wsAction.action || "shortcut";
  const modifiers = wsAction.modifiers ?? [];

  const setWsAction = (patch: Partial<WorkspaceActionDraft>) =>
    onChange({ ...button, action: { ...wsAction, type: "workspace_action", ...patch } });

  return (
    <Card className="p-3.5">
      <div className="flex items-start gap-3">
        <button
          type="button"
          className="mt-0.5 h-8 w-8 shrink-0 rounded-lg border border-border"
          style={{ backgroundColor: button.color_value ? argbToCss(button.color_value) : "transparent" }}
          onClick={() => {
            const idx = PALETTE.findIndex((c) => argbToCss(button.color_value) === c);
            onChange({ ...button, color_value: cssToArgb(PALETTE[(idx + 1) % PALETTE.length]) });
          }}
          title="Cycle colour"
        />

        <div className="flex-1 space-y-2.5">
          <div className="flex gap-2">
            <input
              className={inputClass}
              value={button.label}
              onChange={(e) => onChange({ ...button, label: e.target.value })}
              placeholder="Label"
            />
            <select
              className={`${inputClass} max-w-[9rem]`}
              value={button.icon}
              onChange={(e) => onChange({ ...button, icon: e.target.value })}
            >
              {ICON_KEYS.map((key) => (
                <option key={key} value={key}>
                  {key}
                </option>
              ))}
            </select>
          </div>

          <div className="flex flex-wrap items-center gap-2">
            <select
              className={`${inputClass} max-w-[11rem]`}
              value={actionType}
              onChange={(e) => setWsAction({ action: e.target.value })}
            >
              {ACTION_TYPES.map((t) => (
                <option key={t.value} value={t.value}>
                  {t.label}
                </option>
              ))}
            </select>

            {actionType === "shortcut" && (
              <ShortcutRecorder
                modifiers={modifiers}
                keyName={wsAction.key ?? ""}
                onChange={(mods, key) => setWsAction({ modifiers: mods, key })}
              />
            )}
            {(actionType === "open_app" || actionType === "open_folder") && (
              <input
                className={inputClass}
                placeholder="Path"
                value={wsAction.path ?? ""}
                onChange={(e) => setWsAction({ path: e.target.value })}
              />
            )}
            {actionType === "open_url" && (
              <input
                className={inputClass}
                placeholder="https://…"
                value={wsAction.url ?? ""}
                onChange={(e) => setWsAction({ url: e.target.value })}
              />
            )}
            {actionType === "shell_command" && (
              <input
                className={inputClass}
                placeholder="Command"
                value={wsAction.command ?? ""}
                onChange={(e) => setWsAction({ command: e.target.value })}
              />
            )}
          </div>
        </div>

        <div className="flex flex-col gap-1">
          <IconButton title="Move up" variant="ghost" onClick={() => onMove(-1)}>
            <span className="text-[13px]">↑</span>
          </IconButton>
          <IconButton title="Move down" variant="ghost" onClick={() => onMove(1)}>
            <span className="text-[13px]">↓</span>
          </IconButton>
        </div>
        <IconButton title="Remove button" variant="ghost" onClick={onRemove}>
          <IconTrash className="h-4 w-4" />
        </IconButton>
      </div>
    </Card>
  );
}

function argbToCss(argb: number): string {
  const rgb = argb & 0xffffff;
  return `#${rgb.toString(16).padStart(6, "0")}`;
}
function cssToArgb(css: string): number {
  return 0xff000000 | parseInt(css.slice(1), 16);
}
