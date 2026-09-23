# OMP Usage

An Omarchy bar widget for Oh My Pi subscription usage.

It reads `omp usage --json` and shows only the accounts logged in to OMP on that machine, with provider icons, usage meters, spend amounts, reset times, and plan. Codex, Claude, and Cursor get their own logos; any other provider OMP reports is shown with its initial. Accounts whose provider doesn't report usage are listed with a note instead of being hidden.

All accounts are listed together in one panel. Opening the panel refreshes immediately and then every 3 seconds while it stays open; while closed, it refreshes at the configured interval (default 5 minutes) to keep the bar icon's alert state current.

Anthropic rate-limits its usage endpoint per IP, so Claude is polled live at most once a minute and backs off (up to 15 minutes) while throttled. In between, the widget shows the usage OMP records from normal Claude responses (`omp usage --history`) whenever that is newer than the last live report, with an "Updated … ago" note.

Drag an account's name to change the order; it is saved to `~/.local/state/omarchy/omp-usage-monitor.json`.

Each account shows its exact plan when one is known, otherwise "Subscription" or "API key". Codex, GitHub Copilot, and Gemini plans come from OMP's usage report. Claude and Cursor plans come from `plans.py` (needs `python3`), which reads OMP's stored logins and asks only that provider's own account API (Anthropic's OAuth profile, Cursor's Stripe profile); tokens are never printed or sent elsewhere.

Install by cloning the plugin into `~/.config/omarchy/plugins/` and add `omp.usage-monitor` to the bar layout.
