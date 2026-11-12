import { makeWindow, okReport, errorReport, unavailableReport, toEpoch } from "../lib/report.js";

const SOURCE = "Magpie · Antigravity";

export function parse(text, now) {
  let accounts;
  try { accounts = JSON.parse(text); } catch {
    return errorReport(SOURCE, "No quota reply from Magpie", now);
  }
  if (!Array.isArray(accounts)) return errorReport(SOURCE, "Invalid Magpie quota reply", now);
  accounts = accounts.filter((account) => account.provider === "antigravity");
  if (!accounts.length) return unavailableReport(SOURCE, "No Antigravity account connected", now);
  const failed = accounts.find((account) => account.error);
  if (failed) return errorReport(SOURCE, String(failed.error), now);
  const windows = accounts.flatMap((account) => {
    const all = account.windows ?? [];
    // Pools are shared across models: show each pool once, not a meter per model.
    const pools = all.filter((window) => window.pool);
    return (pools.length ? pools : all).flatMap((window) => {
      if (window.used == null || !Number.isFinite(Number(window.used))) return [];
      const label = window.pool ?? window.name;
      const prefix = accounts.length > 1 ? `${account.user} · ` : "";
      return [makeWindow({
        id: `${account.user ?? "account"}:${label}`,
        short: `${prefix}${label}`,
        long: `${prefix}${window.name}`,
        percent: window.used,
        resetsAt: toEpoch(window.resetsAt),
        durationSec: /7 days/.test(window.name) ? 7 * 24 * 60 * 60 : null,
      })];
    });
  });
  return windows.length
    ? okReport(SOURCE, now, windows, [...new Set(accounts.map((account) => account.plan).filter(Boolean))].join(" · ") || null, Math.min(...accounts.map((account) => toEpoch(account.readAt) ?? now)))
    : unavailableReport(SOURCE, "No Antigravity quota windows available", now);
}

export default {
  id: "antigravity",
  name: "Antigravity",
  icon: "icons/gemini.svg",
  helper: "helpers/antigravity-usage.sh",
  parse,
};
