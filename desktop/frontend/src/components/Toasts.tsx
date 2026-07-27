import { useEffect } from "react";
import { IconCheck, IconClose, IconInfo } from "../lib/icons";

export interface Toast {
  id: number;
  level: string;
  message: string;
}

/** Transient feedback stacked in the bottom-right corner. */
export function Toasts({ toasts, onDismiss }: { toasts: Toast[]; onDismiss: (id: number) => void }) {
  return (
    <div className="pointer-events-none fixed bottom-6 right-6 z-40 flex w-80 flex-col gap-2.5">
      {toasts.map((toast) => (
        <ToastRow key={toast.id} toast={toast} onDismiss={onDismiss} />
      ))}
    </div>
  );
}

function ToastRow({ toast, onDismiss }: { toast: Toast; onDismiss: (id: number) => void }) {
  // Errors stay longer, because they usually carry something worth reading.
  useEffect(() => {
    const lifetime = toast.level === "error" ? 7000 : 4000;
    const timer = setTimeout(() => onDismiss(toast.id), lifetime);
    return () => clearTimeout(timer);
  }, [toast.id, toast.level, onDismiss]);

  const tones: Record<string, string> = {
    success: "border-success/30 text-success",
    error: "border-danger/30 text-danger",
    info: "border-border-hi text-brand-soft",
  };

  return (
    <div
      className={`wd-fade-up pointer-events-auto flex items-start gap-3 rounded-2xl border bg-surface/95 p-3.5 shadow-xl backdrop-blur ${
        tones[toast.level] ?? tones.info
      }`}
    >
      <span className="mt-0.5 shrink-0">
        {toast.level === "success" ? (
          <IconCheck className="h-4 w-4" />
        ) : (
          <IconInfo className="h-4 w-4" />
        )}
      </span>
      <p className="flex-1 text-[13px] leading-relaxed text-ink-dim">{toast.message}</p>
      <button
        onClick={() => onDismiss(toast.id)}
        aria-label="Dismiss"
        className="shrink-0 text-ink-faint transition-colors hover:text-ink"
      >
        <IconClose className="h-3.5 w-3.5" />
      </button>
    </div>
  );
}
