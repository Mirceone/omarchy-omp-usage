# OMP Usage

An Omarchy bar widget for Oh My Pi subscription usage.

It reads `omp usage --json` and shows only the accounts logged in to OMP on that machine, with provider icons, usage meters, spend amounts, reset times, and plan. Codex, Claude, and Cursor get their own logos; any other provider OMP reports is shown with its initial. Accounts whose provider doesn't report usage are listed with a note instead of being hidden.

Install by cloning the plugin into `~/.config/omarchy/plugins/` and add `omp.usage-monitor` to the bar layout.
