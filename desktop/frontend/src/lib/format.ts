/** Formatting helpers shared across the UI. */

/** Human-readable byte count. */
export function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return "0 B";

  const units = ["B", "KB", "MB", "GB", "TB"];
  const exponent = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1);
  const value = bytes / Math.pow(1024, exponent);

  // One decimal reads better for large units; whole bytes never need one.
  return `${exponent === 0 ? value : value.toFixed(value < 10 ? 1 : 0)} ${units[exponent]}`;
}

/** Relative time for feeds — "just now", "4m ago", "yesterday". */
export function timeAgo(millis: number): string {
  if (!millis) return "";

  const seconds = Math.floor((Date.now() - millis) / 1000);
  if (seconds < 45) return "just now";
  if (seconds < 90) return "1m ago";

  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;

  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;

  const days = Math.floor(hours / 24);
  if (days === 1) return "yesterday";
  if (days < 30) return `${days}d ago`;

  return new Date(millis).toLocaleDateString();
}

/** Clock time for notification rows. */
export function clockTime(millis: number): string {
  if (!millis) return "";
  return new Date(millis).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

/** Truncate long clipboard text for a preview line. */
export function preview(text: string, limit = 180): string {
  const collapsed = text.replace(/\s+/g, " ").trim();
  return collapsed.length > limit ? `${collapsed.slice(0, limit)}…` : collapsed;
}

/** Transfer rate, given bytes moved over an elapsed window. */
export function formatRate(bytes: number, millis: number): string {
  if (millis <= 0 || bytes <= 0) return "";
  return `${formatBytes((bytes / millis) * 1000)}/s`;
}

/** Turn a Go error (which arrives as a string or Error) into a message. */
export function errorMessage(err: unknown): string {
  if (typeof err === "string") return err;
  if (err instanceof Error) return err.message;
  if (err && typeof err === "object" && "message" in err) {
    return String((err as { message: unknown }).message);
  }
  return "Something went wrong";
}
