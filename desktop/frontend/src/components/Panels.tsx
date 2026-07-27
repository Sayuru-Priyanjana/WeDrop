import type { main } from "../../wailsjs/go/models";
import { Badge, Button, Card, EmptyState, IconButton, ProgressBar, SectionTitle } from "./ui";
import {
  IconBell,
  IconClipboard,
  IconCopy,
  IconFolder,
  IconSend,
  IconTransfer,
  IconTrash,
} from "../lib/icons";
import { clockTime, formatBytes, preview, timeAgo } from "../lib/format";

/** Transfers, newest first, with live progress for anything in flight. */
export function TransfersPanel({
  transfers,
  onReveal,
  onOpenFolder,
}: {
  transfers: main.TransferView[];
  onReveal: (path: string) => void;
  onOpenFolder: () => void;
}) {
  return (
    <div className="wd-fade-up">
      <SectionTitle
        title="Transfers"
        hint="Files moving between the devices in your ecosystem."
        action={
          <Button variant="ghost" onClick={onOpenFolder}>
            <IconFolder className="h-4 w-4" />
            Open folder
          </Button>
        }
      />

      {transfers.length === 0 ? (
        <EmptyState
          icon={<IconTransfer className="h-6 w-6" />}
          title="No transfers yet"
          hint="Send a file from a device card, or share to WeDrop from another app."
        />
      ) : (
        <div className="space-y-2.5">
          {transfers.map((transfer) => (
            <TransferRow key={transfer.id} transfer={transfer} onReveal={onReveal} />
          ))}
        </div>
      )}
    </div>
  );
}

function TransferRow({
  transfer,
  onReveal,
}: {
  transfer: main.TransferView;
  onReveal: (path: string) => void;
}) {
  const active = transfer.state === "active";
  const ratio = transfer.size > 0 ? transfer.transferred / transfer.size : 0;

  const tone =
    transfer.state === "completed"
      ? "success"
      : transfer.state === "failed"
        ? "danger"
        : transfer.state === "declined"
          ? "warn"
          : "brand";

  const label =
    transfer.state === "completed"
      ? "Done"
      : transfer.state === "failed"
        ? "Failed"
        : transfer.state === "declined"
          ? "Declined"
          : transfer.state === "pending"
            ? "Waiting"
            : `${Math.round(ratio * 100)}%`;

  return (
    <Card className="wd-fade-up p-4">
      <div className="flex items-center gap-3.5">
        <div
          className={`flex h-9 w-9 shrink-0 items-center justify-center rounded-xl ${
            transfer.incoming ? "bg-accent/12 text-accent" : "bg-brand/12 text-brand"
          }`}
        >
          <IconSend className={`h-4 w-4 ${transfer.incoming ? "rotate-180" : ""}`} />
        </div>

        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-2">
            <p className="truncate text-[13.5px] font-medium text-ink">{transfer.filename}</p>
            <Badge tone={tone as never}>{label}</Badge>
          </div>
          <p className="mt-0.5 truncate text-[12px] text-ink-faint">
            {transfer.incoming ? "from" : "to"} {transfer.device_name} ·{" "}
            {active && transfer.size > 0
              ? `${formatBytes(transfer.transferred)} of ${formatBytes(transfer.size)}`
              : formatBytes(transfer.size)}
            {transfer.error ? ` · ${transfer.error}` : ""}
          </p>
        </div>

        {transfer.state === "completed" && transfer.saved_path && (
          <IconButton title="Show in folder" onClick={() => onReveal(transfer.saved_path!)}>
            <IconFolder className="h-4 w-4" />
          </IconButton>
        )}
        <span className="shrink-0 text-[11.5px] text-ink-faint">{timeAgo(transfer.started_at)}</span>
      </div>

      {active && (
        <div className="mt-3">
          <ProgressBar value={ratio} indeterminate={transfer.size === 0} />
        </div>
      )}
    </Card>
  );
}

/** Clipboard history, with one-click restore of any earlier entry. */
export function ClipboardPanel({
  entries,
  autoSync,
  onPush,
  onCopy,
  onClear,
}: {
  entries: main.ClipboardEntry[];
  autoSync: boolean;
  onPush: () => void;
  onCopy: (text: string) => void;
  onClear: () => void;
}) {
  return (
    <div className="wd-fade-up">
      <SectionTitle
        title="Clipboard"
        hint={
          autoSync
            ? "Anything you copy is shared with your ecosystem automatically."
            : "Automatic sync is off — send the clipboard manually when you need it."
        }
        action={
          <div className="flex gap-2">
            <Button variant="ghost" onClick={onClear} title="Clear this list">
              <IconTrash className="h-4 w-4" />
            </Button>
            <Button variant="primary" onClick={onPush}>
              <IconSend className="h-4 w-4" />
              Send now
            </Button>
          </div>
        }
      />

      {entries.length === 0 ? (
        <EmptyState
          icon={<IconClipboard className="h-6 w-6" />}
          title="Nothing shared yet"
          hint="Copy some text on any paired device and it will appear here."
        />
      ) : (
        <div className="space-y-2.5">
          {entries.map((entry, index) => (
            <Card key={`${entry.time}-${index}`} className="group wd-fade-up p-4">
              <div className="flex items-start gap-3">
                <div className="min-w-0 flex-1">
                  <p className="selectable break-words text-[13.5px] leading-relaxed text-ink-dim">
                    {preview(entry.text)}
                  </p>
                  <div className="mt-2 flex items-center gap-2 text-[11.5px] text-ink-faint">
                    <Badge tone={entry.incoming ? "brand" : "neutral"}>
                      {entry.incoming ? `from ${entry.origin_name}` : "this device"}
                    </Badge>
                    <span>{timeAgo(entry.time)}</span>
                  </div>
                </div>
                <IconButton title="Copy again" onClick={() => onCopy(entry.text)}>
                  <IconCopy className="h-4 w-4" />
                </IconButton>
              </div>
            </Card>
          ))}
        </div>
      )}
    </div>
  );
}

/** Notifications mirrored from phones and tablets. */
export function NotificationsPanel({
  notifications,
  onClear,
}: {
  notifications: main.NotificationView[];
  onClear: () => void;
}) {
  return (
    <div className="wd-fade-up">
      <SectionTitle
        title="Notifications"
        hint="Alerts mirrored from the other devices in your ecosystem."
        action={
          notifications.length > 0 ? (
            <Button variant="ghost" onClick={onClear}>
              <IconTrash className="h-4 w-4" />
              Clear
            </Button>
          ) : undefined
        }
      />

      {notifications.length === 0 ? (
        <EmptyState
          icon={<IconBell className="h-6 w-6" />}
          title="Nothing to catch up on"
          hint="Notifications from your phone will show up here once mirroring is enabled on that device."
        />
      ) : (
        <div className="space-y-2.5">
          {notifications.map((notification, index) => (
            <Card key={`${notification.id}-${index}`} className="wd-fade-up p-4">
              <div className="flex items-start gap-3.5">
                <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-xl bg-surface-hi text-ink-faint">
                  <IconBell className="h-4 w-4" />
                </div>
                <div className="min-w-0 flex-1">
                  <div className="flex items-baseline justify-between gap-3">
                    <p className="truncate text-[13.5px] font-medium text-ink">
                      {notification.title || notification.app}
                    </p>
                    <span className="shrink-0 text-[11.5px] text-ink-faint">
                      {clockTime(notification.time)}
                    </span>
                  </div>
                  {notification.body && (
                    <p className="mt-0.5 line-clamp-3 text-[12.5px] leading-relaxed text-ink-dim">
                      {notification.body}
                    </p>
                  )}
                  <p className="mt-1.5 text-[11.5px] text-ink-faint">
                    {notification.app} · {notification.device_name}
                  </p>
                </div>
              </div>
            </Card>
          ))}
        </div>
      )}
    </div>
  );
}
