import { useState } from "react";
import type { main } from "../../wailsjs/go/models";
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
}: {
  device: Device;
  onSendFiles: (deviceId: string) => void;
  onUnpair: (device: Device) => void;
  onPermission: (deviceId: string, capability: string, allowed: boolean) => void;
  onMedia: (deviceId: string, command: string) => void;
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
