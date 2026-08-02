import { useEffect, useState } from "react";
import type { main, storage } from "../../wailsjs/go/models";
import { Button, Card, SectionTitle, SettingRow, Toggle } from "./ui";
import { IconFolder, IconInfo } from "../lib/icons";

/**
 * Every switch in one place. Changes are applied immediately rather than behind
 * a Save button — there is nothing here that is dangerous to toggle, and an
 * unsaved-changes state would just be one more thing to get wrong.
 */
export function SettingsPanel({
  state,
  onUpdate,
  onRename,
  onChooseFolder,
  diagnostics,
  onRefreshDiagnostics,
}: {
  state: main.AppState;
  onUpdate: (settings: storage.Settings) => void;
  onRename: (name: string) => void;
  onChooseFolder: () => void;
  diagnostics: main.Diagnostics | null;
  onRefreshDiagnostics: () => void;
}) {
  const settings = state.settings;
  const [name, setName] = useState(state.self.name);
  const [showDiagnostics, setShowDiagnostics] = useState(false);

  // Keep the field in step when the name changes elsewhere, but never fight
  // the user while they are mid-edit.
  useEffect(() => {
    setName(state.self.name);
  }, [state.self.name]);

  const patch = (changes: Partial<storage.Settings>) => {
    onUpdate({ ...settings, ...changes } as storage.Settings);
  };

  const commitName = () => {
    const trimmed = name.trim();
    if (trimmed && trimmed !== state.self.name) onRename(trimmed);
    else setName(state.self.name);
  };

  return (
    <div className="wd-fade-up max-w-3xl space-y-6 pb-10">
      <div>
        <SectionTitle title="Settings" hint="How this device behaves inside your ecosystem." />

        <Card className="px-6">
          <SettingRow
            title="Device name"
            description="What the other devices call this machine."
            control={
              <input
                value={name}
                onChange={(e) => setName(e.target.value)}
                onBlur={commitName}
                onKeyDown={(e) => e.key === "Enter" && e.currentTarget.blur()}
                maxLength={48}
                className="w-56 rounded-xl border border-border bg-bg-soft px-3.5 py-2 text-[13px] text-ink outline-none transition-colors focus:border-brand"
              />
            }
          />
          <SettingRow
            title="Visible on this network"
            description="Announce this device so others can find and pair with it."
            control={
              <Toggle
                checked={settings.discoverable}
                onChange={(v) => patch({ discoverable: v })}
                label="Visible on this network"
              />
            }
          />
          <SettingRow
            title="Accept new pairing requests"
            description="Turn off once your ecosystem is complete to refuse all new devices."
            control={
              <Toggle
                checked={settings.accept_new_pairing}
                onChange={(v) => patch({ accept_new_pairing: v })}
                label="Accept new pairing requests"
              />
            }
            last
          />
        </Card>
      </div>

      <div>
        <SectionTitle title="Clipboard" />
        <Card className="px-6">
          <SettingRow
            title="Share my clipboard automatically"
            description="Anything you copy here is sent to the rest of your ecosystem."
            control={
              <Toggle
                checked={settings.auto_sync_clipboard}
                onChange={(v) => patch({ auto_sync_clipboard: v })}
                label="Share my clipboard automatically"
              />
            }
          />
          <SettingRow
            title="Apply clipboard from other devices"
            description="Let paired devices update this machine's clipboard."
            control={
              <Toggle
                checked={settings.receive_clipboard}
                onChange={(v) => patch({ receive_clipboard: v })}
                label="Apply clipboard from other devices"
              />
            }
            last
          />
        </Card>
      </div>

      <div>
        <SectionTitle title="Files" />
        <Card className="px-6">
          <SettingRow
            title="Accept files without asking"
            description="Files from paired devices are saved straight to your download folder."
            control={
              <Toggle
                checked={settings.auto_accept_files}
                onChange={(v) => patch({ auto_accept_files: v })}
                label="Accept files without asking"
              />
            }
          />
          <SettingRow
            title="Download folder"
            description={settings.download_dir}
            control={
              <Button variant="ghost" onClick={onChooseFolder}>
                <IconFolder className="h-4 w-4" />
                Change
              </Button>
            }
            last
          />
        </Card>
      </div>

      <div>
        <SectionTitle title="Notifications and media" />
        <Card className="px-6">
          <SettingRow
            title="Show notifications from other devices"
            description="Mirror alerts from your phone and tablet here."
            control={
              <Toggle
                checked={settings.receive_notifications}
                onChange={(v) => patch({ receive_notifications: v })}
                label="Show notifications from other devices"
              />
            }
          />
          <SettingRow
            title="Share my notifications"
            description="Send this device's alerts to the rest of the ecosystem."
            control={
              <Toggle
                checked={settings.share_notifications}
                onChange={(v) => patch({ share_notifications: v })}
                label="Share my notifications"
              />
            }
          />
          <SettingRow
            title="Let other devices control my media"
            description="Play, pause and volume commands from paired devices are applied here."
            control={
              <Toggle
                checked={settings.allow_media_control}
                onChange={(v) => patch({ allow_media_control: v })}
                label="Let other devices control my media"
              />
            }
            last
          />

        </Card>
      </div>

      <div>
        <SectionTitle title="Workspace" />
        <Card className="px-6">
          <SettingRow
            title="Allow running shell commands"
            description="Let paired devices run custom terminal/shell scripts configured in My Buttons."
            control={
              <Toggle
                checked={settings.allow_automation}
                onChange={(v) => patch({ allow_automation: v })}
                label="Allow running shell commands"
              />
            }
            last
          />
        </Card>
      </div>

      <div>
        <SectionTitle
          title="Advanced"
          hint="Show extra detail like network, CPU and memory on a device's card."
        />
        <Card className="px-6">
          <SettingRow
            title="Show advanced device stats"
            description="Adds network, CPU and memory readings to battery and sound."
            control={
              <Toggle
                checked={settings.show_advanced_features}
                onChange={(v) => patch({ show_advanced_features: v })}
                label="Show advanced device stats"
              />
            }
            last
          />
        </Card>
      </div>

      <div>
        <SectionTitle title="Startup" />
        <Card className="px-6">
          <SettingRow
            title="Keep running when the window closes"
            description="Stay in the background so files, clipboard and notifications keep arriving."
            control={
              <Toggle
                checked={settings.run_in_background}
                onChange={(v) => patch({ run_in_background: v })}
                label="Keep running when the window closes"
              />
            }
          />
          <SettingRow
            title="Start with my computer"
            description="Launch WeDrop in the background when you sign in."
            control={
              <Toggle
                checked={settings.start_on_login}
                onChange={(v) => patch({ start_on_login: v })}
                label="Start with my computer"
              />
            }
            last
          />
        </Card>
      </div>

      <div>
        <SectionTitle
          title="This device"
          action={
            <Button
              variant="ghost"
              onClick={() => {
                setShowDiagnostics(!showDiagnostics);
                if (!showDiagnostics) onRefreshDiagnostics();
              }}
            >
              <IconInfo className="h-4 w-4" />
              {showDiagnostics ? "Hide" : "Diagnostics"}
            </Button>
          }
        />
        <Card className="space-y-4 p-6">
          <Field label="Identity fingerprint" value={diagnostics?.fingerprint ?? "—"} mono />
          <Field label="Device ID" value={state.self.device_id} mono />

          {showDiagnostics && diagnostics && (
            <div className="wd-fade-in space-y-4 border-t border-border/60 pt-4">
              <Field label="Listening on TCP port" value={String(diagnostics.listen_port)} mono />
              <Field
                label="Devices seen on the network"
                value={`${diagnostics.peers_seen} nearby · ${diagnostics.paired} paired · ${diagnostics.connected.length} connected`}
              />
              <Field label="Data folder" value={diagnostics.data_dir} mono />
              <p className="text-[12px] leading-relaxed text-ink-faint">
                If a device will not connect, check that both are on the same network, that this port
                is not blocked by a firewall, and that the fingerprints match on each machine.
              </p>
            </div>
          )}
        </Card>
      </div>
    </div>
  );
}

function Field({ label, value, mono }: { label: string; value: string; mono?: boolean }) {
  return (
    <div>
      <p className="mb-1 text-[11.5px] font-medium uppercase tracking-wider text-ink-faint">
        {label}
      </p>
      <p
        className={`selectable break-all rounded-lg bg-bg-soft px-3 py-2 text-[12.5px] text-ink-dim ${
          mono ? "font-mono" : ""
        }`}
      >
        {value}
      </p>
    </div>
  );
}
