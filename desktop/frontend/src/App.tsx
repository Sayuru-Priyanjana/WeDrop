import { useCallback, useEffect, useRef, useState } from "react";
import {
  ChooseDownloadDir,
  ClearClipboardHistory,
  ClearNotifications,
  CopyToClipboard,
  DeleteAppActionProfile,
  GetDiagnostics,
  GetState,
  GetWorkspaceButtons,
  ListAppActionProfiles,
  MarkNotificationsRead,
  OpenDownloadsFolder,
  PairDevice,
  PushClipboard,
  RespondToPairing,
  RespondToTransfer,
  RevealFile,
  SaveAppActionProfile,
  SaveWorkspaceButtons,
  SelectFiles,
  SendFiles,
  SendMediaCommand,
  SendMediaSeek,
  SetDeviceName,
  SetDevicePermission,
  UnpairDevice,
  UpdateSettings,
} from "../wailsjs/go/main/WeDropService";
import type { adaptivecontrols, main, storage } from "../wailsjs/go/models";
import { EventsOn } from "../wailsjs/runtime/runtime";

import { AppActionsPanel } from "./components/AppActionsPanel";
import { DiscoveredDeviceCard, PairedDeviceCard } from "./components/DeviceCard";
import {
  ConfirmUnpairModal,
  IncomingFileModal,
  OutgoingPairingModal,
  PairingRequestModal,
} from "./components/Modals";
import { MyButtonsPanel } from "./components/MyButtonsPanel";
import { ClipboardPanel, NotificationsPanel, TransfersPanel } from "./components/Panels";
import { SettingsPanel } from "./components/SettingsPanel";
import { Toasts, type Toast } from "./components/Toasts";
import { Badge, Button, EmptyState, SectionTitle } from "./components/ui";
import {
  IconBell,
  IconButtonRow,
  IconClipboard,
  IconDevices,
  IconGrid,
  IconRadar,
  IconSettings,
  IconTransfer,
  deviceIcon,
} from "./lib/icons";
import { errorMessage } from "./lib/format";

type Tab =
  | "devices"
  | "transfers"
  | "clipboard"
  | "notifications"
  | "appactions"
  | "mybuttons"
  | "settings";

const TABS: { id: Tab; label: string; icon: typeof IconDevices }[] = [
  { id: "devices", label: "Ecosystem", icon: IconDevices },
  { id: "transfers", label: "Transfers", icon: IconTransfer },
  { id: "clipboard", label: "Clipboard", icon: IconClipboard },
  { id: "notifications", label: "Notifications", icon: IconBell },
  { id: "appactions", label: "App Actions", icon: IconGrid },
  { id: "mybuttons", label: "My Buttons", icon: IconButtonRow },
  { id: "settings", label: "Settings", icon: IconSettings },
];

export default function App() {
  const [state, setState] = useState<main.AppState | null>(null);
  const [tab, setTab] = useState<Tab>("devices");
  const [toasts, setToasts] = useState<Toast[]>([]);
  const [pairingWith, setPairingWith] = useState<string | null>(null);
  const [outgoing, setOutgoing] = useState<{ name: string; code: string } | null>(null);
  const [incomingFile, setIncomingFile] = useState<main.TransferView | null>(null);
  const [unpairTarget, setUnpairTarget] = useState<main.DeviceView | null>(null);
  const [diagnostics, setDiagnostics] = useState<main.Diagnostics | null>(null);
  const [appProfiles, setAppProfiles] = useState<adaptivecontrols.AppProfile[]>([]);
  const [configureTarget, setConfigureTarget] = useState<string | null>(null);

  const toastId = useRef(0);

  const pushToast = useCallback((level: string, message: string) => {
    toastId.current += 1;
    const toast = { id: toastId.current, level, message };
    // Cap the stack so a burst of events cannot cover the whole window.
    setToasts((current) => [...current.slice(-3), toast]);
  }, []);

  const dismissToast = useCallback((id: number) => {
    setToasts((current) => current.filter((t) => t.id !== id));
  }, []);

  const refresh = useCallback(() => {
    GetState()
      .then(setState)
      .catch(() => {
        /* the backend is still starting; the next event will bring state */
      });
  }, []);

  const loadAppProfiles = useCallback(() => {
    ListAppActionProfiles()
      .then((profiles) => setAppProfiles(profiles ?? []))
      .catch(() => undefined);
  }, []);

  useEffect(() => {
    refresh();
    loadAppProfiles();

    // The backend pushes a coalesced snapshot whenever anything changes, so the
    // UI does not poll. The slow interval below is only a safety net in case an
    // event is missed while the window is hidden.
    const unsubscribers = [
      EventsOn("state", (next: main.AppState) => setState(next)),
      EventsOn("toast", (payload: { level: string; message: string }) =>
        pushToast(payload.level, payload.message),
      ),
      EventsOn("pairing:outgoing", (payload: { name: string; verification_code: string }) =>
        setOutgoing({ name: payload.name, code: payload.verification_code }),
      ),
      EventsOn("transfer:incoming", (transfer: main.TransferView) => setIncomingFile(transfer)),
      EventsOn("transfer:progress", (transfer: main.TransferView) => {
        setState((current) => {
          if (!current) return current;
          const transfers = current.transfers.some((t) => t.id === transfer.id)
            ? current.transfers.map((t) => (t.id === transfer.id ? transfer : t))
            : [transfer, ...current.transfers];
          return { ...current, transfers } as main.AppState;
        });
      }),
      EventsOn("clipboard:received", (from: string) => pushToast("info", `Clipboard from ${from}`)),
      // A paired phone tapped "Configure this app" for something with no
      // profile yet — jump to the App Actions tab pre-selected on it.
      EventsOn("app-actions:open", (exe: string) => {
        setConfigureTarget(exe);
        setTab("appactions");
      }),
      // A paired phone tapped "Configure on desktop" for its (empty) My
      // Buttons — jump to the My Buttons tab. Nothing to preselect: it's one
      // shared list for every phone, not per-device.
      EventsOn("my-buttons:open", () => setTab("mybuttons")),
    ];

    const safetyNet = setInterval(refresh, 15000);

    return () => {
      unsubscribers.forEach((off) => off());
      clearInterval(safetyNet);
    };
  }, [refresh, loadAppProfiles, pushToast]);

  // Clear the unread badge the moment the user actually looks at the feed.
  useEffect(() => {
    if (tab === "notifications" && state?.notifications.some((n) => !n.read)) {
      MarkNotificationsRead();
    }
  }, [tab, state?.notifications]);

  const run = useCallback(
    async (action: Promise<unknown>, success?: string) => {
      try {
        await action;
        if (success) pushToast("success", success);
      } catch (err) {
        pushToast("error", errorMessage(err));
      }
    },
    [pushToast],
  );

  const handlePair = async (deviceId: string) => {
    setPairingWith(deviceId);
    try {
      await PairDevice(deviceId);
    } catch (err) {
      pushToast("error", errorMessage(err));
    } finally {
      setPairingWith(null);
      setOutgoing(null);
    }
  };

  const handleSendFiles = async (deviceId: string) => {
    try {
      const paths = await SelectFiles();
      if (!paths || paths.length === 0) return;
      setTab("transfers");
      await SendFiles(deviceId, paths);
    } catch (err) {
      pushToast("error", errorMessage(err));
    }
  };

  const loadDiagnostics = useCallback(() => {
    GetDiagnostics()
      .then(setDiagnostics)
      .catch(() => undefined);
  }, []);

  if (!state) return <SplashScreen />;
  if (state.error) return <StartupError message={state.error} />;

  const unreadCount = state.notifications.filter((n) => !n.read).length;
  const activeTransfers = state.transfers.filter((t) => t.state === "active").length;

  return (
    <div className="flex h-screen w-screen overflow-hidden bg-bg text-ink">
      <Sidebar
        tab={tab}
        onTab={setTab}
        self={state.self}
        connected={state.paired.filter((d) => d.connected).length}
        paired={state.paired.length}
        unread={unreadCount}
        activeTransfers={activeTransfers}
      />

      <main className="relative flex-1 overflow-y-auto">
        {/* A soft glow anchors the layout without competing with content. */}
        <div className="pointer-events-none absolute -top-40 right-0 h-[420px] w-[420px] rounded-full bg-brand/12 blur-[130px]" />

        <div className="relative mx-auto max-w-5xl px-10 py-9">
          {tab === "devices" && (
            <DevicesTab
              state={state}
              pairingWith={pairingWith}
              onPair={handlePair}
              onSendFiles={handleSendFiles}
              onUnpair={setUnpairTarget}
              onPermission={(id, cap, allowed) => run(SetDevicePermission(id, cap, allowed))}
              onMedia={(id, command) => run(SendMediaCommand(id, command))}
              onSeek={(id, positionMs) => run(SendMediaSeek(id, positionMs))}
            />
          )}

          {tab === "transfers" && (
            <TransfersPanel
              transfers={state.transfers}
              onReveal={(path) => run(RevealFile(path))}
              onOpenFolder={() => run(OpenDownloadsFolder())}
            />
          )}

          {tab === "clipboard" && (
            <ClipboardPanel
              entries={state.clipboard}
              autoSync={state.settings.auto_sync_clipboard}
              onPush={() => run(PushClipboard(), "Clipboard sent")}
              onCopy={(text) => run(CopyToClipboard(text), "Copied")}
              onClear={() => ClearClipboardHistory()}
            />
          )}

          {tab === "notifications" && (
            <NotificationsPanel
              notifications={state.notifications}
              onClear={() => ClearNotifications()}
            />
          )}

          {tab === "appactions" && (
            <AppActionsPanel
              profiles={appProfiles}
              initialExe={configureTarget}
              onSave={async (profile) => {
                await run(SaveAppActionProfile(profile), "Saved");
                loadAppProfiles();
              }}
              onDelete={async (exe) => {
                await run(DeleteAppActionProfile(exe), "Removed");
                loadAppProfiles();
              }}
            />
          )}

          {tab === "mybuttons" && (
            <MyButtonsPanel
              onLoad={() => GetWorkspaceButtons()}
              onSave={async (buttons) => {
                await run(SaveWorkspaceButtons(buttons), "Saved");
              }}
            />
          )}

          {tab === "settings" && (
            <SettingsPanel
              state={state}
              diagnostics={diagnostics}
              onRefreshDiagnostics={loadDiagnostics}
              onUpdate={(settings: storage.Settings) => run(UpdateSettings(settings))}
              onRename={(name) => run(SetDeviceName(name), "Device renamed")}
              onChooseFolder={() => run(ChooseDownloadDir())}
            />
          )}
        </div>
      </main>

      {state.pairing && (
        <PairingRequestModal
          prompt={state.pairing}
          onRespond={(deviceId, accept) => run(RespondToPairing(deviceId, accept))}
        />
      )}

      {outgoing && !state.pairing && (
        <OutgoingPairingModal
          name={outgoing.name}
          code={outgoing.code}
          onCancel={() => setOutgoing(null)}
        />
      )}

      {incomingFile && (
        <IncomingFileModal
          transfer={incomingFile}
          onRespond={(transferId, accept) => {
            setIncomingFile(null);
            run(RespondToTransfer(transferId, accept));
          }}
        />
      )}

      {unpairTarget && (
        <ConfirmUnpairModal
          device={unpairTarget}
          onCancel={() => setUnpairTarget(null)}
          onConfirm={() => {
            const target = unpairTarget;
            setUnpairTarget(null);
            run(UnpairDevice(target.device_id), `${target.name} removed`);
          }}
        />
      )}

      <Toasts toasts={toasts} onDismiss={dismissToast} />
    </div>
  );
}

function Sidebar({
  tab,
  onTab,
  self,
  connected,
  paired,
  unread,
  activeTransfers,
}: {
  tab: Tab;
  onTab: (tab: Tab) => void;
  self: main.DeviceView;
  connected: number;
  paired: number;
  unread: number;
  activeTransfers: number;
}) {
  const SelfGlyph = deviceIcon(self.form_factor);

  return (
    <aside className="flex w-[248px] shrink-0 flex-col border-r border-border bg-bg-soft/80 px-5 py-7">
      <div className="mb-9 flex items-center gap-3 px-1">
        <div className="flex h-10 w-10 items-center justify-center rounded-2xl bg-gradient-to-br from-brand to-accent shadow-lg shadow-brand/25">
          <svg
            viewBox="0 0 24 24"
            className="h-5 w-5 text-white"
            fill="none"
            stroke="currentColor"
            strokeWidth={2}
            strokeLinecap="round"
            strokeLinejoin="round"
          >
            <path d="M12 3v12M7.5 10.5L12 15l4.5-4.5M5 19h14" />
          </svg>
        </div>
        <div>
          <h1 className="text-[17px] font-semibold tracking-tight">WeDrop</h1>
          <p className="text-[11.5px] text-ink-faint">
            {connected} of {paired} connected
          </p>
        </div>
      </div>

      <nav className="flex flex-1 flex-col gap-1">
        {TABS.map(({ id, label, icon: Glyph }) => {
          const badge = id === "notifications" ? unread : id === "transfers" ? activeTransfers : 0;
          const active = tab === id;
          return (
            <button
              key={id}
              onClick={() => onTab(id)}
              className={`flex items-center gap-3 rounded-xl px-3.5 py-2.5 text-[13.5px] transition-all duration-200 ${
                active
                  ? "bg-brand/12 font-medium text-brand-soft"
                  : "text-ink-dim hover:bg-surface-hi hover:text-ink"
              }`}
            >
              <Glyph className="h-[18px] w-[18px]" />
              <span className="flex-1 text-left">{label}</span>
              {badge > 0 && (
                <span className="flex h-5 min-w-5 items-center justify-center rounded-full bg-brand px-1.5 text-[11px] font-semibold text-white">
                  {badge}
                </span>
              )}
            </button>
          );
        })}
      </nav>

      <div className="mt-6 flex items-center gap-3 rounded-2xl border border-border bg-surface/60 px-3.5 py-3">
        <div className="flex h-9 w-9 items-center justify-center rounded-xl bg-surface-hi text-ink-dim">
          <SelfGlyph className="h-4 w-4" />
        </div>
        <div className="min-w-0">
          <p className="truncate text-[13px] font-medium text-ink">{self.name}</p>
          <p className="text-[11.5px] text-ink-faint">This device</p>
        </div>
      </div>
    </aside>
  );
}

function DevicesTab({
  state,
  pairingWith,
  onPair,
  onSendFiles,
  onUnpair,
  onPermission,
  onMedia,
  onSeek,
}: {
  state: main.AppState;
  pairingWith: string | null;
  onPair: (deviceId: string) => void;
  onSendFiles: (deviceId: string) => void;
  onUnpair: (device: main.DeviceView) => void;
  onPermission: (deviceId: string, capability: string, allowed: boolean) => void;
  onMedia: (deviceId: string, command: string) => void;
  onSeek: (deviceId: string, positionMs: number) => void;
}) {
  return (
    <div className="space-y-10">
      <div>
        <SectionTitle
          title="My ecosystem"
          hint="Devices that trust each other and sync automatically."
          action={
            state.paired.length > 0 ? (
              <Badge tone="success">
                {state.paired.filter((d) => d.connected).length} connected
              </Badge>
            ) : undefined
          }
        />

        {state.paired.length === 0 ? (
          <EmptyState
            icon={<IconDevices className="h-6 w-6" />}
            title="Your ecosystem is empty"
            hint="Devices you pair appear here and start sharing clipboard, files and notifications straight away."
          />
        ) : (
          <div className="grid gap-3.5 lg:grid-cols-2">
            {state.paired.map((device) => (
              <PairedDeviceCard
                key={device.device_id}
                device={device}
                onSendFiles={onSendFiles}
                onUnpair={onUnpair}
                onPermission={onPermission}
                onMedia={onMedia}
                onSeek={onSeek}
                showAdvanced={state.settings.show_advanced_features}
              />
            ))}
          </div>
        )}
      </div>

      <div>
        <SectionTitle
          title="Nearby"
          hint="Other devices running WeDrop on this network."
          action={
            <span className="flex items-center gap-2 text-[12.5px] text-ink-faint">
              <IconRadar className="h-4 w-4 animate-pulse" />
              Scanning
            </span>
          }
        />

        {state.discovered.length === 0 ? (
          <EmptyState
            icon={<IconRadar className="h-6 w-6" />}
            title="Nothing new nearby"
            hint="Open WeDrop on your other devices and make sure they are on the same Wi-Fi network."
          />
        ) : (
          <div className="space-y-2.5">
            {state.discovered.map((device) => (
              <DiscoveredDeviceCard
                key={device.device_id}
                device={device}
                pairing={pairingWith === device.device_id}
                onPair={onPair}
              />
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

function SplashScreen() {
  return (
    <div className="flex h-screen w-screen items-center justify-center bg-bg">
      <div className="wd-fade-in flex flex-col items-center gap-4">
        <div className="h-10 w-10 animate-spin rounded-full border-2 border-border border-t-brand" />
        <p className="text-[13px] text-ink-faint">Starting WeDrop…</p>
      </div>
    </div>
  );
}

function StartupError({ message }: { message: string }) {
  return (
    <div className="flex h-screen w-screen items-center justify-center bg-bg p-10">
      <div className="wd-scale-in max-w-md rounded-[22px] border border-danger/30 bg-surface p-8 text-center">
        <h2 className="text-lg font-semibold text-danger">WeDrop could not start</h2>
        <p className="selectable mt-3 text-[13.5px] leading-relaxed text-ink-dim">{message}</p>
        <p className="mt-4 text-[12.5px] text-ink-faint">
          This usually means another copy of WeDrop is already running, or the app cannot write to
          its data folder.
        </p>
        <Button variant="ghost" className="mt-6" onClick={() => window.location.reload()}>
          Try again
        </Button>
      </div>
    </div>
  );
}
