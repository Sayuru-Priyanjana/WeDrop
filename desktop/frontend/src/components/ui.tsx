import type { ReactNode } from "react";

/** Small presentational building blocks reused across every panel. */

export function Card({
  children,
  className = "",
  onClick,
}: {
  children: ReactNode;
  className?: string;
  onClick?: () => void;
}) {
  return (
    <div
      onClick={onClick}
      className={`rounded-[18px] border border-white/[0.07] bg-white/[0.028] backdrop-blur-sm ${className}`}
    >
      {children}
    </div>
  );
}

export function SectionTitle({
  title,
  hint,
  action,
}: {
  title: string;
  hint?: string;
  action?: ReactNode;
}) {
  return (
    <div className="mb-4 flex items-end justify-between gap-4">
      <div>
        <h2 className="text-lg font-semibold tracking-tight text-ink">{title}</h2>
        {hint && <p className="mt-0.5 text-[13px] text-ink-faint">{hint}</p>}
      </div>
      {action}
    </div>
  );
}

type ButtonVariant = "primary" | "ghost" | "danger" | "subtle";

const buttonStyles: Record<ButtonVariant, string> = {
  primary:
    "bg-brand text-white hover:bg-brand-soft shadow-lg shadow-brand/25 disabled:shadow-none",
  ghost:
    "bg-transparent text-ink-dim hover:bg-surface-hi hover:text-ink border border-border",
  subtle: "bg-surface-hi text-ink hover:bg-border",
  danger: "bg-danger/12 text-danger hover:bg-danger/22 border border-danger/25",
};

export function Button({
  children,
  onClick,
  variant = "subtle",
  disabled,
  className = "",
  title,
}: {
  children: ReactNode;
  onClick?: () => void;
  variant?: ButtonVariant;
  disabled?: boolean;
  className?: string;
  title?: string;
}) {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      title={title}
      className={`inline-flex items-center justify-center gap-2 rounded-xl px-3.5 py-2 text-[13px] font-medium transition-all duration-200 disabled:cursor-not-allowed disabled:opacity-45 ${buttonStyles[variant]} ${className}`}
    >
      {children}
    </button>
  );
}

export function IconButton({
  children,
  onClick,
  title,
  variant = "subtle",
  disabled,
}: {
  children: ReactNode;
  onClick?: () => void;
  title: string;
  variant?: ButtonVariant;
  disabled?: boolean;
}) {
  return (
    <button
      onClick={onClick}
      title={title}
      aria-label={title}
      disabled={disabled}
      className={`inline-flex h-9 w-9 items-center justify-center rounded-xl transition-all duration-200 disabled:cursor-not-allowed disabled:opacity-40 ${buttonStyles[variant]}`}
    >
      {children}
    </button>
  );
}

export function Toggle({
  checked,
  onChange,
  disabled,
  label,
}: {
  checked: boolean;
  onChange: (value: boolean) => void;
  disabled?: boolean;
  label: string;
}) {
  return (
    <button
      role="switch"
      aria-checked={checked}
      aria-label={label}
      disabled={disabled}
      onClick={() => onChange(!checked)}
      className={`relative h-6 w-11 shrink-0 rounded-full transition-colors duration-250 disabled:cursor-not-allowed disabled:opacity-40 ${
        checked ? "bg-brand" : "bg-border"
      }`}
    >
      <span
        className={`absolute top-0.5 h-5 w-5 rounded-full bg-white shadow transition-all duration-250 ${
          checked ? "left-[22px]" : "left-0.5"
        }`}
      />
    </button>
  );
}

/** A labelled row wrapping a control — the backbone of the settings screen. */
export function SettingRow({
  title,
  description,
  control,
  last,
}: {
  title: string;
  description?: string;
  control: ReactNode;
  last?: boolean;
}) {
  return (
    <div
      className={`flex items-center justify-between gap-6 py-4 ${
        last ? "" : "border-b border-border/60"
      }`}
    >
      <div className="min-w-0">
        <p className="text-[14px] font-medium text-ink">{title}</p>
        {description && (
          <p className="mt-0.5 text-[12.5px] leading-relaxed text-ink-faint">{description}</p>
        )}
      </div>
      <div className="shrink-0">{control}</div>
    </div>
  );
}

export function StatusDot({ state }: { state: "connected" | "online" | "offline" }) {
  const colours = {
    connected: "bg-success shadow-[0_0_8px_rgba(47,206,143,0.75)]",
    online: "bg-warn",
    offline: "bg-ink-faint/50",
  };
  return <span className={`inline-block h-2 w-2 shrink-0 rounded-full ${colours[state]}`} />;
}

export function EmptyState({
  icon,
  title,
  hint,
  action,
}: {
  icon: ReactNode;
  title: string;
  hint: string;
  action?: ReactNode;
}) {
  return (
    <div className="flex flex-col items-center justify-center rounded-[18px] border border-dashed border-border px-8 py-14 text-center">
      <div className="mb-4 flex h-12 w-12 items-center justify-center rounded-2xl bg-surface-hi text-ink-faint">
        {icon}
      </div>
      <p className="text-[14px] font-medium text-ink-dim">{title}</p>
      <p className="mt-1 max-w-sm text-[12.5px] leading-relaxed text-ink-faint">{hint}</p>
      {action && <div className="mt-5">{action}</div>}
    </div>
  );
}

export function Badge({
  children,
  tone = "neutral",
}: {
  children: ReactNode;
  tone?: "neutral" | "success" | "warn" | "danger" | "brand";
}) {
  const tones = {
    neutral: "bg-surface-hi text-ink-dim",
    success: "bg-success/15 text-success",
    warn: "bg-warn/15 text-warn",
    danger: "bg-danger/15 text-danger",
    brand: "bg-brand/15 text-brand-soft",
  };
  return (
    <span
      className={`inline-flex items-center rounded-full px-2 py-0.5 text-[11px] font-medium tracking-wide ${tones[tone]}`}
    >
      {children}
    </span>
  );
}

export function ProgressBar({ value, indeterminate }: { value: number; indeterminate?: boolean }) {
  return (
    <div
      className={`h-1.5 w-full overflow-hidden rounded-full bg-border ${
        indeterminate ? "wd-shimmer" : ""
      }`}
    >
      {!indeterminate && (
        <div
          className="h-full rounded-full bg-gradient-to-r from-brand to-accent transition-[width] duration-300 ease-out"
          style={{ width: `${Math.min(100, Math.max(0, value * 100))}%` }}
        />
      )}
    </div>
  );
}
