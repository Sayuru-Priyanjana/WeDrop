import { useEffect, useState } from "react";
import { adaptivecontrols } from "../../wailsjs/go/models";
import { Badge, Button, Card, EmptyState, IconButton, SectionTitle, IconPicker, ICON_KEYS } from "./ui";
import { ShortcutRecorder } from "./ShortcutRecorder";
import { IconGrid, IconPlus, IconTrash } from "../lib/icons";

/** Plain-data mirrors of the generated Wails classes, used for local editing
 * state — the generated classes carry a convertValues method, so a plain
 * object built by spreading/mapping never structurally matches them. Only
 * converted back via AppProfile.createFrom(...) at the point of saving. */
interface WorkspaceActionDraft {
  type: string;
  action: string;
  modifiers?: string[];
  key?: string;
  path?: string;
  url?: string;
  command?: string;
  window_id?: number;
}
interface ActionDraft {
  id: string;
  label: string;
  icon: string;
  color_value: number;
  predefined: boolean;
  action: WorkspaceActionDraft;
}
interface ProfileDraft {
  exe: string;
  display_name: string;
  actions: ActionDraft[];
}

/** Monochrome palette for a sleek B&W look. */
const PALETTE = [
  "#111111", "#333333", "#555555", "#777777",
  "#999999", "#BBBBBB", "#DDDDDD", "#FFFFFF",
];

const ACTION_TYPES: { value: string; label: string }[] = [
  { value: "shortcut", label: "Keyboard shortcut" },
  { value: "open_app", label: "Open application" },
  { value: "open_folder", label: "Open folder" },
  { value: "open_url", label: "Open website" },
  { value: "shell_command", label: "Shell command" },
];



const inputClass =
  "w-full rounded-xl border border-border bg-bg px-3 py-1.5 text-[13px] text-ink outline-none transition-colors focus:border-brand";

function randomPaletteColor(): number {
  const css = PALETTE[Math.floor(Math.random() * PALETTE.length)];
  return 0xff000000 | parseInt(css.slice(1), 16);
}

function newAction(order: number): ActionDraft {
  return {
    id: `custom-${Date.now()}-${order}`,
    label: "New action",
    icon: "bolt",
    // A random colour rather than "no override" (0) — a fresh action should
    // already look like it belongs to the same varied set as the others,
    // not default to a flat grey until someone manually cycles it.
    color_value: randomPaletteColor(),
    predefined: false,
    action: { type: "workspace_action", action: "shortcut", modifiers: ["ctrl"], key: "" },
  };
}

export function AppActionsPanel({
  profiles,
  initialExe,
  onSave,
  onDelete,
}: {
  profiles: adaptivecontrols.AppProfile[];
  initialExe: string | null;
  onSave: (profile: adaptivecontrols.AppProfile) => Promise<void>;
  onDelete: (exe: string) => Promise<void>;
}) {
  const [selectedExe, setSelectedExe] = useState<string | null>(initialExe);
  const [draft, setDraft] = useState<ProfileDraft | null>(null);
  const [adding, setAdding] = useState(false);
  const [newExe, setNewExe] = useState("");
  const [newName, setNewName] = useState("");
  const [dirty, setDirty] = useState(false);

  // A remote "configure this app" request (or picking a different app in the
  // list) always jumps here and loads a fresh draft — any unsaved edits to
  // the previous app are discarded, same as navigating away from a form.
  useEffect(() => {
    setSelectedExe(initialExe);
  }, [initialExe]);

  useEffect(() => {
    if (!selectedExe) {
      setDraft(null);
      return;
    }
    const existing = profiles.find((p) => p.exe === selectedExe);
    setDraft(
      existing
        ? {
            exe: existing.exe,
            display_name: existing.display_name,
            actions: existing.actions.map((a) => ({ ...a, action: { ...a.action } })),
          }
        : { exe: selectedExe, display_name: "", actions: [] },
    );
    setDirty(false);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedExe, profiles.length]);

  const updateDraft = (fn: (d: ProfileDraft) => ProfileDraft) => {
    setDraft((current) => (current ? fn(current) : current));
    setDirty(true);
  };

  const handleAddApp = () => {
    const exe = newExe.trim().toLowerCase();
    if (!exe) return;
    setSelectedExe(exe);
    setDraft({ exe, display_name: newName.trim() || exe, actions: [] });
    setDirty(true);
    setAdding(false);
    setNewExe("");
    setNewName("");
  };

  const handleSave = async () => {
    if (!draft) return;
    await onSave(adaptivecontrols.AppProfile.createFrom(draft));
    setDirty(false);
  };

  const handleDelete = async () => {
    if (!selectedExe) return;
    await onDelete(selectedExe);
    setSelectedExe(null);
    setDraft(null);
  };

  return (
    <div className="grid grid-cols-[15rem_1fr] gap-6">
      <div>
        <SectionTitle title="Applications" hint="Apps with Dynamic Controls buttons." />
        <div className="space-y-1.5">
          {profiles.map((p) => (
            <button
              key={p.exe}
              onClick={() => setSelectedExe(p.exe)}
              className={`flex w-full items-center justify-between rounded-xl px-3.5 py-2.5 text-left text-[13px] transition-colors ${
                selectedExe === p.exe
                  ? "bg-brand/12 font-medium text-brand-soft"
                  : "text-ink-dim hover:bg-surface-hi hover:text-ink"
              }`}
            >
              <span className="truncate">{p.display_name || p.exe}</span>
              <span className="ml-2 shrink-0 text-[11px] text-ink-faint">{p.actions.length}</span>
            </button>
          ))}
          {profiles.length === 0 && (
            <p className="px-3.5 py-2 text-[12.5px] text-ink-faint">No apps configured yet.</p>
          )}
        </div>

        {adding ? (
          <Card className="mt-3 space-y-2.5 p-3.5">
            <input
              className={inputClass}
              placeholder="Executable, e.g. photoshop.exe"
              value={newExe}
              onChange={(e) => setNewExe(e.target.value)}
              autoFocus
            />
            <input
              className={inputClass}
              placeholder="Display name (optional)"
              value={newName}
              onChange={(e) => setNewName(e.target.value)}
            />
            <div className="flex gap-2">
              <Button variant="primary" className="flex-1" onClick={handleAddApp} disabled={!newExe.trim()}>
                Add
              </Button>
              <Button variant="ghost" onClick={() => setAdding(false)}>
                Cancel
              </Button>
            </div>
          </Card>
        ) : (
          <Button variant="ghost" className="mt-3 w-full" onClick={() => setAdding(true)}>
            <IconPlus className="h-4 w-4" />
            Add app
          </Button>
        )}
      </div>

      <div>
        {!draft ? (
          <EmptyState
            icon={<IconGrid className="h-6 w-6" />}
            title="Pick an app to configure"
            hint="Choose an application on the left, or add a new one, to edit its Dynamic Controls buttons."
          />
        ) : (
          <div>
            <SectionTitle
              title={draft.display_name || draft.exe}
              hint={draft.exe}
              action={
                <div className="flex gap-2">
                  <Button variant="danger" onClick={handleDelete}>
                    <IconTrash className="h-4 w-4" />
                    Delete app
                  </Button>
                  <Button variant="primary" onClick={handleSave} disabled={!dirty}>
                    Save changes
                  </Button>
                </div>
              }
            />

            <div className="mb-4">
              <label className="mb-1 block text-[12px] text-ink-faint">Display name</label>
              <input
                className={`${inputClass} max-w-xs`}
                value={draft.display_name}
                onChange={(e) => updateDraft((d) => ({ ...d, display_name: e.target.value }))}
              />
            </div>

            <div className="space-y-3">
              {draft.actions.map((action, i) => (
                <div key={action.id} className="relative" style={{ zIndex: draft.actions.length - i }}>
                  <ActionRow
                    action={action}
                    onChange={(next) =>
                      updateDraft((d) => ({
                        ...d,
                        actions: d.actions.map((a, j) => (j === i ? next : a)),
                      }))
                    }
                    onRemove={() =>
                      updateDraft((d) => ({ ...d, actions: d.actions.filter((_, j) => j !== i) }))
                    }
                  />
                </div>
              ))}
            </div>

            <Button
              variant="ghost"
              className="mt-3"
              onClick={() => updateDraft((d) => ({ ...d, actions: [...d.actions, newAction(d.actions.length)] }))}
            >
              <IconPlus className="h-4 w-4" />
              Add action
            </Button>
          </div>
        )}
      </div>
    </div>
  );
}

function ActionRow({
  action,
  onChange,
  onRemove,
}: {
  action: ActionDraft;
  onChange: (next: ActionDraft) => void;
  onRemove: () => void;
}) {
  const wsAction = action.action ?? { type: "workspace_action", action: "shortcut" };
  const actionType = wsAction.action || "shortcut";
  const modifiers = wsAction.modifiers ?? [];

  const setWsAction = (patch: Partial<typeof wsAction>) =>
    onChange({ ...action, action: { ...wsAction, type: "workspace_action", ...patch } });

  return (
    <Card className="p-3.5">
      <div className="flex items-start gap-3">
        <button
          type="button"
          className="mt-0.5 h-8 w-8 shrink-0 rounded-lg border border-border"
          style={{ backgroundColor: action.color_value ? argbToCss(action.color_value) : "transparent" }}
          onClick={() => {
            const idx = PALETTE.findIndex((c) => argbToCss(action.color_value) === c);
            const next = PALETTE[(idx + 1) % PALETTE.length];
            onChange({ ...action, color_value: cssToArgb(next) });
          }}
          title="Cycle colour"
        />

        <div className="flex-1 space-y-2.5">
          <div className="flex gap-2">
            <input
              className={inputClass}
              value={action.label}
              onChange={(e) => onChange({ ...action, label: e.target.value })}
              placeholder="Label"
            />
            <IconPicker value={action.icon} onChange={(icon) => onChange({ ...action, icon })} />
            {action.predefined && <Badge tone="brand">Predefined</Badge>}
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

        <IconButton title="Remove action" variant="ghost" onClick={onRemove}>
          <IconTrash className="h-4 w-4" />
        </IconButton>
      </div>
    </Card>
  );
}

/** ARGB int (WorkspaceButton.colorValue's convention) <-> #RRGGBB CSS. */
function argbToCss(argb: number): string {
  const rgb = argb & 0xffffff;
  return `#${rgb.toString(16).padStart(6, "0")}`;
}
function cssToArgb(css: string): number {
  return 0xff000000 | parseInt(css.slice(1), 16);
}
