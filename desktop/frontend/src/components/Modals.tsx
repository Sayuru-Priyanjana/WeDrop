import { useEffect, useState } from "react";
import type { main } from "../../wailsjs/go/models";
import { Button } from "./ui";
import { IconShield, IconSend, deviceIcon } from "../lib/icons";
import { formatBytes } from "../lib/format";

/** A dimmed, centred overlay used by every modal. */
function Overlay({ children }: { children: React.ReactNode }) {
  return (
    <div className="wd-fade-in fixed inset-0 z-50 flex items-center justify-center bg-black/65 p-6 backdrop-blur-sm">
      <div className="wd-scale-in w-full max-w-[420px] rounded-[22px] border border-border-hi bg-surface p-7 shadow-2xl">
        {children}
      </div>
    </div>
  );
}

/** The six digits shown on both devices during pairing. */
function VerificationCode({ code }: { code: string }) {
  return (
    <div className="my-6">
      <p className="mb-2.5 text-center text-[11.5px] font-medium uppercase tracking-widest text-ink-faint">
        Verification code
      </p>
      <div className="flex justify-center gap-2">
        {code.split("").map((digit, i) => (
          <span
            key={i}
            className="flex h-12 w-10 items-center justify-center rounded-xl border border-border-hi bg-bg-soft font-mono text-xl font-semibold text-brand-soft"
          >
            {digit}
          </span>
        ))}
      </div>
      <p className="mt-3 text-center text-[12px] leading-relaxed text-ink-faint">
        Only continue if the other device is showing these same digits.
      </p>
    </div>
  );
}

/** Prompt shown when another device asks to join this ecosystem. */
export function PairingRequestModal({
  prompt,
  onRespond,
}: {
  prompt: main.PairingPrompt;
  onRespond: (deviceId: string, accept: boolean) => void;
}) {
  const [remaining, setRemaining] = useState(() =>
    Math.max(0, Math.round((prompt.expires_at - Date.now()) / 1000)),
  );

  useEffect(() => {
    const timer = setInterval(() => {
      setRemaining(Math.max(0, Math.round((prompt.expires_at - Date.now()) / 1000)));
    }, 1000);
    return () => clearInterval(timer);
  }, [prompt.expires_at]);

  const Glyph = deviceIcon(prompt.form_factor);

  return (
    <Overlay>
      <div className="flex flex-col items-center text-center">
        <div className="mb-5 flex h-14 w-14 items-center justify-center rounded-2xl bg-brand/12 text-brand">
          <Glyph className="h-7 w-7" />
        </div>

        <h3 className="text-xl font-semibold text-ink">Join your ecosystem?</h3>
        <p className="mt-2 text-[13.5px] leading-relaxed text-ink-dim">
          <strong className="text-ink">{prompt.name}</strong> ({prompt.platform}) wants to pair with
          this device.
        </p>

        <VerificationCode code={prompt.verification_code} />

        <p className="mb-5 text-[12px] text-ink-faint">
          Expires in {remaining}s · from {prompt.address}
        </p>

        <div className="flex w-full gap-3">
          <Button
            variant="ghost"
            className="flex-1 py-2.5"
            onClick={() => onRespond(prompt.device_id, false)}
          >
            Decline
          </Button>
          <Button
            variant="primary"
            className="flex-1 py-2.5"
            onClick={() => onRespond(prompt.device_id, true)}
          >
            <IconShield className="h-4 w-4" />
            Accept
          </Button>
        </div>
      </div>
    </Overlay>
  );
}

/** Shown on the initiating side while the other user decides. */
export function OutgoingPairingModal({
  name,
  code,
  onCancel,
}: {
  name: string;
  code: string;
  onCancel: () => void;
}) {
  return (
    <Overlay>
      <div className="flex flex-col items-center text-center">
        <div className="mb-5 flex h-14 w-14 items-center justify-center rounded-2xl bg-brand/12 text-brand">
          <IconShield className="h-7 w-7" />
        </div>

        <h3 className="text-xl font-semibold text-ink">Waiting for {name}</h3>
        <p className="mt-2 text-[13.5px] leading-relaxed text-ink-dim">
          Accept the request on that device to finish pairing.
        </p>

        <VerificationCode code={code} />

        <Button variant="ghost" className="w-full py-2.5" onClick={onCancel}>
          Hide
        </Button>
      </div>
    </Overlay>
  );
}

/** Prompt for an incoming file when auto-accept is switched off. */
export function IncomingFileModal({
  transfer,
  onRespond,
}: {
  transfer: main.TransferView;
  onRespond: (transferId: string, accept: boolean) => void;
}) {
  return (
    <Overlay>
      <div className="flex flex-col items-center text-center">
        <div className="mb-5 flex h-14 w-14 items-center justify-center rounded-2xl bg-accent/12 text-accent">
          <IconSend className="h-7 w-7 rotate-180" />
        </div>

        <h3 className="text-xl font-semibold text-ink">Incoming file</h3>
        <p className="mt-2 text-[13.5px] leading-relaxed text-ink-dim">
          <strong className="text-ink">{transfer.device_name}</strong> wants to send you a file.
        </p>

        <div className="my-6 w-full rounded-xl border border-border bg-bg-soft px-4 py-3 text-left">
          <p className="truncate text-[13.5px] font-medium text-ink">{transfer.filename}</p>
          <p className="mt-0.5 text-[12px] text-ink-faint">{formatBytes(transfer.size)}</p>
        </div>

        <div className="flex w-full gap-3">
          <Button
            variant="ghost"
            className="flex-1 py-2.5"
            onClick={() => onRespond(transfer.id, false)}
          >
            Decline
          </Button>
          <Button
            variant="primary"
            className="flex-1 py-2.5"
            onClick={() => onRespond(transfer.id, true)}
          >
            Accept
          </Button>
        </div>
      </div>
    </Overlay>
  );
}

/** Confirmation before removing a device, since it needs re-pairing after. */
export function ConfirmUnpairModal({
  device,
  onConfirm,
  onCancel,
}: {
  device: main.DeviceView;
  onConfirm: () => void;
  onCancel: () => void;
}) {
  return (
    <Overlay>
      <div className="flex flex-col items-center text-center">
        <h3 className="text-xl font-semibold text-ink">Remove {device.name}?</h3>
        <p className="mt-2.5 text-[13.5px] leading-relaxed text-ink-dim">
          It will stop syncing immediately, and you will both need to pair again to reconnect.
        </p>

        <div className="mt-7 flex w-full gap-3">
          <Button variant="ghost" className="flex-1 py-2.5" onClick={onCancel}>
            Keep
          </Button>
          <Button variant="danger" className="flex-1 py-2.5" onClick={onConfirm}>
            Remove
          </Button>
        </div>
      </div>
    </Overlay>
  );
}
