# OMP Usage

An Omarchy bar widget for Oh My Pi subscription usage.

It reads `omp usage --json` and shows only the accounts logged in to OMP on that machine, with provider icons, usage meters, spend amounts, reset times, and plan. Codex, Claude, and Cursor get their own logos; any other provider OMP reports is shown with its initial. Accounts whose provider doesn't report usage are listed with a note instead of being hidden.

All accounts are listed together in one panel. Opening the panel refreshes immediately and then every 3 seconds while it stays open; while closed, it refreshes at the configured interval (default 5 minutes) to keep the bar icon's alert state current.

Install by cloning the plugin into `~/.config/omarchy/plugins/` and add `omp.usage-monitor` to the bar layout.
