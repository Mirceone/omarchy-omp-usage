import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import type { Component, KeybindingsManager, Theme, TUI } from "@oh-my-pi/pi-tui";

type UsageLimit = {
  label?: string;
  scope?: { tier?: string; modelId?: string };
  window?: { label?: string; resetsAt?: number };
  amount?: { usedFraction?: number; remainingFraction?: number };
  status?: string;
};

type UsageReport = {
  provider?: string;
  fetchedAt?: number;
  limits?: UsageLimit[];
  metadata?: { planType?: string; allowed?: boolean; limitReached?: boolean };
  resetCredits?: { availableCount?: number };
};

type UsageSnapshot = {
  reports?: UsageReport[];
  accountsWithoutUsage?: unknown[];
  disabledCredentials?: unknown[];
};

type StatsSnapshot = {
  overall?: {
    totalRequests?: number;
    totalInputTokens?: number;
    totalOutputTokens?: number;
    totalCacheReadTokens?: number;
    totalCacheWriteTokens?: number;
    totalCost?: number;
  };
  byModel?: Array<{
    model?: string;
    provider?: string;
    totalInputTokens?: number;
    totalOutputTokens?: number;
    totalCacheReadTokens?: number;
    totalCacheWriteTokens?: number;
  }>;
};

type MonitorData = { usage: UsageSnapshot; stats: StatsSnapshot };

async function runOmpJson<T>(args: string[]): Promise<T> {
  const proc = Bun.spawn(["omp", ...args], { stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  if (exitCode !== 0) throw new Error(stderr.trim() || `omp ${args.join(" ")} exited ${exitCode}`);

  // `omp stats --json` may write a progress line before its JSON payload.
  const start = stdout.indexOf("{");
  if (start < 0) throw new Error(`omp ${args.join(" ")} did not return JSON`);
  return JSON.parse(stdout.slice(start)) as T;
}

async function fetchMonitorData(): Promise<MonitorData> {
  const [usage, stats] = await Promise.all([
    runOmpJson<UsageSnapshot>(["usage", "--json"]),
    runOmpJson<StatsSnapshot>(["stats", "--json"]),
  ]);
  return { usage, stats };
}

function providerName(provider: string | undefined): string {
  const names: Record<string, string> = {
    "openai-codex": "OpenAI Codex",
    anthropic: "Anthropic",
  };
  return names[provider || ""] || provider || "Unknown provider";
}

function formatCount(value: number | undefined): string {
  const number = Number(value || 0);
  if (number >= 1_000_000) return `${(number / 1_000_000).toFixed(number >= 10_000_000 ? 0 : 1)}M`;
  if (number >= 1_000) return `${(number / 1_000).toFixed(number >= 10_000 ? 0 : 1)}K`;
  return String(number);
}

function formatReset(timestamp: number | undefined): string {
  if (!timestamp) return "reset unknown";
  const minutes = Math.max(0, Math.ceil((timestamp - Date.now()) / 60_000));
  const days = Math.floor(minutes / 1_440);
  const hours = Math.floor((minutes % 1_440) / 60);
  if (days) return `resets in ${days}d ${hours}h`;
  if (hours) return `resets in ${hours}h ${minutes % 60}m`;
  return `resets in ${Math.max(1, minutes)}m`;
}

function meter(fraction: number | undefined, width = 24): string {
  const used = Math.max(0, Math.min(1, Number(fraction || 0)));
  const filled = Math.round(used * width);
  return `${"█".repeat(filled)}${"░".repeat(width - filled)}`;
}

function displayLimit(limit: UsageLimit): string {
  const used = Math.max(0, Math.min(1, Number(limit.amount?.usedFraction || 0)));
  const detail = [limit.scope?.tier, limit.scope?.modelId].filter(Boolean).join(" · ");
  const label = `${limit.label || limit.window?.label || "Usage"}${detail ? ` (${detail})` : ""}`;
  const status = limit.status && limit.status !== "ok" ? ` · ${limit.status}` : "";
  return `  ${label.padEnd(36)} ${meter(used)} ${(used * 100).toFixed(1)}% used · ${formatReset(limit.window?.resetsAt)}${status}`;
}

function buildLines(data: MonitorData, theme: Theme, width: number): string[] {
  const line = (text = "") => text.length > width ? text.slice(0, Math.max(0, width - 1)) : text;
  const title = theme.fg("accent", "Usage Monitor");
  const muted = (text: string) => theme.fg("muted", text);
  const lines = [line(title), line(muted("OMP subscriptions and local token activity")), ""];
  const reports = data.usage.reports || [];

  if (reports.length === 0) {
    lines.push(line(muted("No authenticated subscriptions reported by OMP.")));
  } else {
    for (const report of reports) {
      const plan = report.metadata?.planType ? ` · ${report.metadata.planType}` : "";
      const blocked = report.metadata?.limitReached ? " · limit reached" : report.metadata?.allowed === false ? " · unavailable" : "";
      const credits = report.resetCredits?.availableCount ? ` · ${report.resetCredits.availableCount} saved reset${report.resetCredits.availableCount === 1 ? "" : "s"}` : "";
      lines.push(line(theme.fg("accent", `${providerName(report.provider)}${plan}${credits}${blocked}`)));
      for (const limit of report.limits || []) lines.push(line(displayLimit(limit)));
      lines.push("");
    }
  }

  const overall = data.stats.overall;
  if (overall) {
    const totalTokens = Number(overall.totalInputTokens || 0) + Number(overall.totalOutputTokens || 0)
      + Number(overall.totalCacheReadTokens || 0) + Number(overall.totalCacheWriteTokens || 0);
    lines.push(line(theme.fg("accent", "Local OMP activity")));
    lines.push(line(`  ${formatCount(overall.totalRequests)} requests · ${formatCount(totalTokens)} tokens · $${Number(overall.totalCost || 0).toFixed(2)} estimated API cost`));

    const models = (data.stats.byModel || []).slice(0, 4);
    for (const model of models) {
      const tokens = Number(model.totalInputTokens || 0) + Number(model.totalOutputTokens || 0)
        + Number(model.totalCacheReadTokens || 0) + Number(model.totalCacheWriteTokens || 0);
      lines.push(line(`  ${String(model.model || "Unknown model").padEnd(28)} ${formatCount(tokens)} tokens`));
    }
  }

  if ((data.usage.accountsWithoutUsage?.length || 0) > 0 || (data.usage.disabledCredentials?.length || 0) > 0) {
    lines.push("");
    lines.push(line(muted("Some authenticated accounts have no usage endpoint or are disabled.")));
  }
  lines.push("");
  lines.push(line(muted("Esc/q closes · r refreshes")));
  return lines;
}

class UsageMonitorPanel implements Component {
  private loading = false;
  private error = "";

  constructor(
    private readonly tui: TUI,
    private readonly theme: Theme,
    private readonly done: () => void,
    private data: MonitorData,
  ) {}

  handleInput(input: string): void {
    if (input === "\u001b" || input.toLowerCase() === "q") {
      this.done();
      return;
    }
    if (input.toLowerCase() === "r" && !this.loading) {
      this.loading = true;
      void fetchMonitorData()
        .then((data) => { this.data = data; this.error = ""; })
        .catch((error: unknown) => { this.error = error instanceof Error ? error.message : String(error); })
        .finally(() => { this.loading = false; this.tui.requestRender(); });
      this.tui.requestRender();
    }
  }

  render(width: number): readonly string[] {
    if (this.loading) return [this.theme.fg("accent", "Refreshing usage monitor…")];
    if (this.error) return [this.theme.fg("error", `Usage monitor: ${this.error}`), "", "Press r to retry or Esc to close."];
    return buildLines(this.data, this.theme, width);
  }
}

export default function usageMonitor(pi: ExtensionAPI): void {
  pi.registerCommand("omp-usage", {
    description: "Open the OMP subscription and token usage monitor",
    handler: async (_args, ctx) => {
      if (!ctx.hasUI) return;
      try {
        const data = await fetchMonitorData();
        await ctx.ui.custom<void>((tui, theme, _keybindings, done) => new UsageMonitorPanel(tui, theme, done, data), { overlay: true });
      } catch (error) {
        ctx.ui.notify(`Usage monitor failed: ${error instanceof Error ? error.message : String(error)}`, "error");
      }
    },
  });
}
