import { useRef, useState } from "react";
import type { PointerEvent as ReactPointerEvent } from "react";
import type { main, protocol } from "../../wailsjs/go/models";
import { Badge, Button, IconButton, StatusDot, Toggle } from "./ui";
import {
  IconClipboard,
  IconBell,
  IconNext,
  IconPlay,
  IconPrev,
  IconSend,
  IconTrash,
  IconVolumeDown,
  IconVolumeUp,
  deviceIcon,
} from "../lib/icons";
import { timeAgo } from "../lib/format";

type Device = main.DeviceView;

/** A paired device: status, quick actions, per-device permissions. */
export function PairedDeviceCard({
  device,
  onSendFiles,
  onUnpair,
  onPermission,
  onMedia,
  onSeek,
  showAdvanced,
}: {
  device: Device;
  onSendFiles: (deviceId: string) => void;
  onUnpair: (device: Device) => void;
  onPermission: (deviceId: string, capability: string, allowed: boolean) => void;
  onMedia: (deviceId: string, command: string) => void;
  onSeek: (deviceId: string, positionMs: number) => void;
  showAdvanced: boolean;
}) {
  const [expanded, setExpanded] = useState(false);
  const Glyph = deviceIcon(device.form_factor);

  const status = device.connected ? "connected" : device.online ? "online" : "offline";
  const statusLabel = device.connected
    ? "Connected"
    : device.online
      ? "On the network"
      : device.last_seen
        ? `Last seen ${timeAgo(device.last_seen)}`
        : "Offline";

  return (
    <div className="wd-fade-up overflow-hidden rounded-[18px] border border-border bg-surface/70 transition-colors duration-300 hover:border-border-hi">
      <div className="flex items-start gap-4 p-5">
        <div
          className={`relative flex h-12 w-12 shrink-0 items-center justify-center rounded-2xl border ${
            device.connected
              ? "border-success/30 bg-success/10 text-success"
              : "border-border bg-surface-hi text-ink-dim"
          } ${device.connected ? "wd-ring" : ""}`}
        >
          <Glyph className="h-6 w-6" />
        </div>

        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-2">
            <h3 className="truncate text-[15px] font-semibold text-ink">{device.name}</h3>
            {device.connected && <Badge tone="success">Synced</Badge>}
          </div>
          <div className="mt-1 flex items-center gap-2 text-[12.5px] text-ink-faint">
            <StatusDot state={status} />
            <span className="truncate">
              {device.platform} · {statusLabel}
            </span>
          </div>
        </div>

        <div className="flex shrink-0 gap-1.5">
          <IconButton
            title={device.online ? "Send files" : "Device is offline"}
            onClick={() => onSendFiles(device.device_id)}
            disabled={!device.online}
            variant="primary"
          >
            <IconSend className="h-4 w-4" />
          </IconButton>
          <IconButton title="Remove from ecosystem" variant="danger" onClick={() => onUnpair(device)}>
            <IconTrash className="h-4 w-4" />
          </IconButton>
        </div>
      </div>

      {/* Live health from the peer, shown while connected. */}
      {device.connected && device.health && (
        <HealthStrip health={device.health} showAdvanced={showAdvanced} />
      )}

      {/* Now-playing, when the peer reports it. */}
      {device.connected && device.media?.has_media && (
        <NowPlaying
          media={device.media}
          onSeek={(positionMs) => onSeek(device.device_id, positionMs)}
        />
      )}

      {/* Media remote, only useful while a session is actually live. */}
      {device.connected && device.allow_media && (
        <div className="flex items-center gap-1.5 border-t border-border/60 px-5 py-3">
          <span className="mr-1 text-[11.5px] font-medium uppercase tracking-wider text-ink-faint">
            Media
          </span>
          <IconButton title="Previous track" onClick={() => onMedia(device.device_id, "prev")}>
            <IconPrev className="h-4 w-4" />
          </IconButton>
          <IconButton title="Play or pause" onClick={() => onMedia(device.device_id, "play_pause")}>
            <IconPlay className="h-4 w-4" />
          </IconButton>
          <IconButton title="Next track" onClick={() => onMedia(device.device_id, "next")}>
            <IconNext className="h-4 w-4" />
          </IconButton>
          <div className="mx-1 h-5 w-px bg-border" />
          <IconButton title="Volume down" onClick={() => onMedia(device.device_id, "vol_down")}>
            <IconVolumeDown className="h-4 w-4" />
          </IconButton>
          <IconButton title="Volume up" onClick={() => onMedia(device.device_id, "vol_up")}>
            <IconVolumeUp className="h-4 w-4" />
          </IconButton>
        </div>
      )}

      <button
        onClick={() => setExpanded(!expanded)}
        className="flex w-full items-center justify-between border-t border-border/60 px-5 py-2.5 text-[12.5px] text-ink-faint transition-colors hover:bg-surface-hi/50 hover:text-ink-dim"
      >
        <span>What this device may do</span>
        <span className={`transition-transform duration-200 ${expanded ? "rotate-180" : ""}`}>
          ⌄
        </span>
      </button>

      {expanded && (
        <div className="wd-fade-in space-y-3 border-t border-border/60 bg-bg-soft/40 px-5 py-4">
          <PermissionRow
            icon={<IconClipboard className="h-4 w-4" />}
            label="Share clipboard"
            checked={device.allow_clipboard}
            onChange={(v) => onPermission(device.device_id, "clipboard", v)}
          />
          <PermissionRow
            icon={<IconSend className="h-4 w-4" />}
            label="Send me files"
            checked={device.allow_files}
            onChange={(v) => onPermission(device.device_id, "files", v)}
          />
          <PermissionRow
            icon={<IconBell className="h-4 w-4" />}
            label="Mirror notifications"
            checked={device.allow_notifications}
            onChange={(v) => onPermission(device.device_id, "notifications", v)}
          />
          <PermissionRow
            icon={<IconPlay className="h-4 w-4" />}
            label="Control my media"
            checked={device.allow_media}
            onChange={(v) => onPermission(device.device_id, "media", v)}
          />
        </div>
      )}
    </div>
  );
}

function PermissionRow({
  icon,
  label,
  checked,
  onChange,
}: {
  icon: React.ReactNode;
  label: string;
  checked: boolean;
  onChange: (value: boolean) => void;
}) {
  return (
    <div className="flex items-center justify-between gap-4">
      <div className="flex items-center gap-2.5 text-[13px] text-ink-dim">
        <span className="text-ink-faint">{icon}</span>
        {label}
      </div>
      <Toggle checked={checked} onChange={onChange} label={label} />
    </div>
  );
}

/** A compact row of the peer's battery (and, once opted in, network/CPU/memory) readings. */
function HealthStrip({
  health,
  showAdvanced,
}: {
  health: protocol.DeviceHealth;
  showAdvanced: boolean;
}) {
  const items: { icon: React.ReactNode; label: string }[] = [];

  if (health.battery >= 0) {
    items.push({
      icon: health.charging ? "⚡" : "🔋",
      label: `${health.battery}%`,
    });
  }
  // Network/CPU/memory are detail most people never look at day to day —
  // kept out of the default view, shown only behind Settings > Advanced.
  if (showAdvanced) {
    if (health.network_type && health.network_type !== "offline") {
      items.push({
        icon: health.network_type === "wifi" ? "📶" : "🔌",
        label: health.network_type === "wifi" ? "Wi-Fi" : "Wired",
      });
    }
    if (health.cpu_percent >= 0) items.push({ icon: "🧠", label: `CPU ${health.cpu_percent}%` });
    if (health.mem_percent >= 0) items.push({ icon: "💾", label: `Mem ${health.mem_percent}%` });
  }

  if (items.length === 0) return null;

  return (
    <div className="flex flex-wrap items-center gap-3 border-t border-border/60 px-5 py-2.5 text-[12px] text-ink-faint">
      {items.map((item, i) => (
        <span key={i} className="flex items-center gap-1.5">
          <span className="text-[13px] leading-none">{item.icon}</span>
          {item.label}
        </span>
      ))}
    </div>
  );
}

/** Now-playing summary with album art and a draggable seek bar. */
function NowPlaying({
  media,
  onSeek,
}: {
  media: protocol.MediaState;
  onSeek: (positionMs: number) => void;
}) {
  const known = media.position >= 0 && media.duration > 0;
  const trackRef = useRef<HTMLDivElement>(null);
  const [dragRatio, setDragRatio] = useState<number | null>(null);

  const liveRatio = known ? Math.min(1, media.position / media.duration) : 0;
  const ratio = dragRatio ?? liveRatio;

  const fmt = (ms: number) => {
    const total = Math.floor(ms / 1000);
    const m = Math.floor(total / 60);
    const s = total % 60;
    return `${m}:${s.toString().padStart(2, "0")}`;
  };

  const ratioAt = (clientX: number) => {
    const el = trackRef.current;
    if (!el) return 0;
    const rect = el.getBoundingClientRect();
    return Math.min(1, Math.max(0, (clientX - rect.left) / rect.width));
  };

  const handlePointerDown = (e: ReactPointerEvent<HTMLDivElement>) => {
    if (!known) return;
    e.currentTarget.setPointerCapture(e.pointerId);
    setDragRatio(ratioAt(e.clientX));
  };

  const handlePointerMove = (e: ReactPointerEvent<HTMLDivElement>) => {
    if (dragRatio === null) return;
    setDragRatio(ratioAt(e.clientX));
  };

  const handlePointerUp = (e: ReactPointerEvent<HTMLDivElement>) => {
    if (dragRatio === null) return;
    const finalRatio = ratioAt(e.clientX);
    setDragRatio(null);
    onSeek(Math.round(finalRatio * media.duration));
  };

  return (
    <div className="border-t border-border/60 px-5 py-3">
      <div className="flex items-center gap-3">
        {media.artwork ? (
          <img
            src={`data:image/jpeg;base64,${media.artwork}`}
            alt=""
            className="h-10 w-10 shrink-0 rounded-lg object-cover"
          />
        ) : (
          <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg bg-surface-hi text-accent">
            ♪
          </div>
        )}
        <div className="min-w-0 flex-1 text-[12.5px]">
          <div className="truncate font-medium text-ink">{media.title || "Unknown track"}</div>
          {media.artist && <div className="truncate text-ink-faint">{media.artist}</div>}
        </div>
      </div>
      <div
        ref={trackRef}
        onPointerDown={handlePointerDown}
        onPointerMove={handlePointerMove}
        onPointerUp={handlePointerUp}
        className={`group relative mt-2.5 flex h-3 w-full items-center ${known ? "cursor-pointer" : ""}`}
      >
        <div className="h-1 w-full overflow-hidden rounded-full bg-border">
          <div
            className={`h-full rounded-full bg-gradient-to-r from-accent to-brand ${
              dragRatio === null ? "transition-[width] duration-500" : ""
            }`}
            style={{ width: `${ratio * 100}%` }}
          />
        </div>
        {known && (
          <div
            className="absolute h-2.5 w-2.5 -translate-x-1/2 rounded-full bg-ink opacity-0 shadow transition-opacity group-hover:opacity-100"
            style={{ left: `${ratio * 100}%` }}
          />
        )}
      </div>
      {known && (
        <div className="mt-1 flex justify-between text-[10.5px] text-ink-faint">
          <span>{fmt(dragRatio === null ? media.position : ratio * media.duration)}</span>
          <span>{fmt(media.duration)}</span>
        </div>
      )}
    </div>
  );
}

/** A device seen on the network that is not yet part of the ecosystem. */
export function DiscoveredDeviceCard({
  device,
  pairing,
  onPair,
}: {
  device: Device;
  pairing: boolean;
  onPair: (deviceId: string) => void;
}) {
  const Glyph = deviceIcon(device.form_factor);

  return (
    <div className="wd-fade-up flex items-center gap-4 rounded-[18px] border border-border bg-surface/40 p-5 transition-colors duration-300 hover:border-border-hi">
      <div className="flex h-11 w-11 shrink-0 items-center justify-center rounded-2xl border border-border bg-surface-hi text-ink-faint">
        <Glyph className="h-5 w-5" />
      </div>

      <div className="min-w-0 flex-1">
        <h3 className="truncate text-[14.5px] font-medium text-ink">{device.name}</h3>
        <p className="mt-0.5 truncate text-[12.5px] text-ink-faint">
          {device.platform} · {device.ip}
        </p>
      </div>

      <Button variant="primary" onClick={() => onPair(device.device_id)} disabled={pairing}>
        {pairing ? "Waiting…" : "Add to ecosystem"}
      </Button>
    </div>
  );
}
