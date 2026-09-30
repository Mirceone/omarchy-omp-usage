import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "omp.usage-monitor"
  ipcTarget: "omp.usage-monitor"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property int refreshIntervalSec: Math.max(30, Number(settings && settings.refreshIntervalSec || 300))

  property var reports: []
  property string errorText: ""
  property double nowMs: Date.now()

  property var history: ({})
  property var knownProviders: []
  property double lastFullAt: 0
  property var pending: null
  property var slowNextAt: ({})
  property var slowBackoffMs: ({})
  // Exact plan / access type per account, from plans.py.
  property var plans: ({})
  // Account keys in the order the user dragged them into (persisted).
  property var savedOrder: []
  // Collapsed group headers, persisted. Keys: "g|<provider>",
  // "w|<provider>|<periodId>", "a|<provider>|<periodId>|<accountKey>".
  property var collapsed: ({})
  property string dragKey: ""
  // Period ("w|…") the dragged account is being moved in.
  property string dragPeriod: ""
  property int dropIndex: -1
  // Drop-line Y in `column` coordinates, set by the dragged account card.
  property real dropY: 0
  // Provider -> period -> account nesting derived from displayReports.
  // Rebuilt on data/order changes only; collapsing toggles visibility.
  property var groups: []
  // Layout constants for the three grouping levels.
  readonly property real periodIndent: Style.space(12)
  readonly property real accountIndent: Style.space(24)
  readonly property real chevW: Math.ceil(Style.font.body * 0.9)

  readonly property string statePath: Quickshell.env("HOME") + "/.local/state/omarchy/omp-usage-monitor.json"
  readonly property string credentialStore: Quickshell.env("HOME") + "/.omp/agent/agent.db"
  // Identity of every enabled OMP credential (no secrets); a change means an
  // account was logged in or out. null until the first read.
  property var accountsSignature: null
  // Re-run discovery as soon as the in-flight usage pass finishes.
  property bool rediscoverQueued: false

  readonly property var displayReports: {
    var list = reports.map(withHistory).map(dedupeShared)
    var rank = {}
    for (var i = 0; i < savedOrder.length; i++) rank[savedOrder[i]] = i
    var position = {}
    for (var j = 0; j < list.length; j++) position[reportKey(list[j])] = j
    return list.slice().sort(function(a, b) {
      var ka = reportKey(a), kb = reportKey(b)
      var ra = rank[ka] === undefined ? savedOrder.length + position[ka] : rank[ka]
      var rb = rank[kb] === undefined ? savedOrder.length + position[kb] : rank[kb]
      return ra - rb
    })
  }

  function groupByKey(key) {
    for (var i = 0; i < groups.length; i++)
      if ("g|" + groups[i].provider === key) return groups[i]
    return null
  }

  // Account keys of one period ("w|<provider>|<periodId>"), in panel order.
  function visiblePeriodAccounts(periodKey) {
    for (var i = 0; i < groups.length; i++) {
      var periods = groups[i].periods || []
      for (var j = 0; j < periods.length; j++)
        if (periods[j].key === periodKey)
          return periods[j].accounts.map(function(a) { return a.key })
    }
    return []
  }

  onDisplayReportsChanged: { rebuildGroups(); syncSections() }

  // Bring sectionModel to the provider order with moves/inserts/removes
  // only, so existing provider delegates are kept rather than recreated.
  function syncSections() {
    var keys = groups.map(function(g) { return "g|" + g.provider })
    for (var i = 0; i < keys.length; i++) {
      if (i < sectionModel.count && sectionModel.get(i).key === keys[i]) continue
      var found = -1
      for (var j = i + 1; j < sectionModel.count; j++)
        if (sectionModel.get(j).key === keys[i]) { found = j; break }
      if (found >= 0) sectionModel.move(found, i, 1)
      else sectionModel.insert(i, { key: keys[i] })
    }
    while (sectionModel.count > keys.length) sectionModel.remove(sectionModel.count - 1)
  }

  // Provider -> period -> account nesting for the panel. Order inside every
  // level follows displayReports, so a drag reorder shows up in all of them.
  function rebuildGroups() {
    var result = []
    var seen = {}
    for (var i = 0; i < displayReports.length; i++) {
      var r = displayReports[i]
      var g = seen[r.provider]
      if (!g) { g = { provider: r.provider, periods: [] }; seen[r.provider] = g; result.push(g) }
      addToPeriods(g, r)
    }
    groups = result
  }

  function addToPeriods(group, report) {
    var buckets = {}
    var order = []
    var limits = report.limits || []
    if (report.noUsage || limits.length === 0) {
      buckets["none"] = []
      order.push("none")
    } else {
      for (var i = 0; i < limits.length; i++) {
        var pid = periodId(limits[i])
        if (!buckets[pid]) { buckets[pid] = []; order.push(pid) }
        buckets[pid].push(limits[i])
      }
    }
    for (var j = 0; j < order.length; j++) {
      var entry = accountEntry(report, buckets[order[j]])
      var existing = null
      for (var k = 0; k < group.periods.length; k++)
        if (group.periods[k].id === order[j]) { existing = group.periods[k]; break }
      if (existing) existing.accounts.push(entry)
      else group.periods.push(newPeriod(group.provider, order[j], buckets[order[j]][0] || null, entry))
    }
  }

  function newPeriod(provider, pid, sample, firstEntry) {
    return {
      key: "w|" + provider + "|" + pid,
      id: pid,
      label: periodLabel(pid, sample),
      accounts: [firstEntry]
    }
  }


  function accountEntry(report, limits) {
    var metadata = report.metadata || {}
    return {
      key: reportKey(report),
      report: report,
      email: String(metadata.email || metadata.accountId || ""),
      limits: limits,
      noUsage: !!report.noUsage,
      resetCount: report && report.resetCredits ? Number(report.resetCredits.availableCount) || 0 : 0
    }
  }

  function periodId(limit) {
    var w = (limit && limit.window) || {}
    var scope = (limit && limit.scope) || {}
    return String(w.id || scope.windowId || "other")
  }

  function periodLabel(pid, sample) {
    if (pid === "none") return "No usage reported"
    var w = (sample && sample.window) || {}
    if (w.label) return String(w.label)
    return String(pid || "Other").split(/[-_]/).map(function(part) {
      return part ? part[0].toUpperCase() + part.slice(1) : ""
    }).join(" ")
  }

  // OMP reports a shared pool once per model family (e.g. an anthropic row
  // and an openai row with the same sharedGroup and identical figures): one
  // pool, one row. Keeps the first occurrence.
  function dedupeShared(report) {
    if (!report || report.noUsage || !Array.isArray(report.limits)) return report
    var seen = {}
    var limits = []
    for (var i = 0; i < report.limits.length; i++) {
      var l = report.limits[i]
      var scope = l.scope || {}
      var key = scope.sharedGroup ? "shared|" + scope.sharedGroup + "|" + periodId(l) : String(l.id)
      if (seen[key]) continue
      seen[key] = true
      limits.push(l)
    }
    return Object.assign({}, report, { limits: limits })
  }

  function isCollapsed(key) { return !!collapsed[key] }

  function toggleGroup(key) {
    var next = Object.assign({}, collapsed)
    if (next[key]) delete next[key]
    else next[key] = true
    collapsed = next
    saveState()
  }

  function saveState() {
    stateFile.setText(JSON.stringify({ order: savedOrder, collapsed: collapsed }, null, 2) + "\n")
  }

  ListModel { id: sectionModel }

  readonly property bool alarming: {
    for (var r = 0; r < displayReports.length; r++) {
      var limits = displayReports[r].limits || []
      for (var i = 0; i < limits.length; i++)
        if (!windowExpired(limits[i]) && Number(usedFraction(limits[i])) >= 0.9) return true
    }
    return false
  }

  // Worst (highest) used fraction across an account's live limits, or
  // undefined when it has no limit a meter can be drawn from.
  function worstUsed(report) {
    if (!report || report.noUsage) return undefined
    var worst
    var limits = report.limits || []
    for (var i = 0; i < limits.length; i++) {
      if (windowExpired(limits[i])) continue
      var used = usedFraction(limits[i])
      if (used === undefined || isNaN(used)) continue
      worst = worst === undefined ? used : Math.max(worst, used)
    }
    return worst
  }

  // Bar icon meters: first two accounts (in the panel's order) that report
  // usage. Each is { name, used, level 0..4, alarming }.
  readonly property var meters: {
    var list = []
    for (var i = 0; i < displayReports.length && list.length < 2; i++) {
      var used = worstUsed(displayReports[i])
      if (used === undefined) continue
      var left = Math.max(0, 1 - used)
      list.push({
        name: providerName(displayReports[i].provider),
        used: used,
        level: Math.max(0, Math.min(4, Math.ceil(left * 4 - 1e-9))),
        alarming: used >= 0.9
      })
    }
    return list
  }

  // An account beyond the two shown meters is running low.
  readonly property bool hiddenAlarm: {
    var shown = 0
    for (var i = 0; i < displayReports.length; i++) {
      var used = worstUsed(displayReports[i])
      if (used === undefined) continue
      if (shown++ >= 2 && used >= 0.9) return true
    }
    return false
  }

  readonly property string meterTooltip: {
    var parts = []
    for (var i = 0; i < displayReports.length; i++) {
      var r = displayReports[i]
      if (r.noUsage) continue
      var status = root.accountSummary({ report: r, limits: r.limits })
      if (status) parts.push(shortAccount(r) + ": " + status)
    }
    return parts.length > 0 ? parts.join(" · ") : "OMP Usage"
  }

  // "saputraedooo11@gmail.com" -> "saputraedooo1…"; falls back to the
  // provider name when the account reports no identity.
  function shortAccount(report) {
    var metadata = report && report.metadata ? report.metadata : {}
    var email = String(metadata.email || metadata.accountId || "")
    if (email) {
      var local = email.split("@")[0] || email
      return local.length > 14 ? local.slice(0, 13) + "…" : local
    }
    return providerName(report && report.provider)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function providerName(id) {
    var names = { "openai-codex": "Codex", "anthropic": "Claude", "cursor": "Cursor" }
    if (names[id]) return names[id]
    // Same title-casing OMP itself uses for provider ids ("github-copilot" -> "Github Copilot").
    return String(id || "Unknown provider").split(/[-_]/).map(function(part) {
      return part ? part[0].toUpperCase() + part.slice(1) : ""
    }).join(" ")
  }

  function providerIcon(id) {
    if (id === "openai-codex") return Qt.resolvedUrl("assets/codex.svg")
    if (id === "anthropic") return Qt.resolvedUrl("assets/claude.svg")
    if (id === "cursor") return Qt.resolvedUrl("assets/cursor.svg")
    return ""
  }

  function formatPlanName(value) {
    return String(value).split(/[-_ ]+/).map(function(part) {
      return part ? part[0].toUpperCase() + part.slice(1).toLowerCase() : ""
    }).join(" ")
  }

  // Exact plan when any source knows it ("Plus plan", "Pro plan"), otherwise
  // the universal access type ("Subscription" / "API key").
  function planText(report) {
    if (!report) return ""
    var metadata = report.metadata || {}
    var exact = metadata.planType || metadata.plan || metadata.currentTierName
    if (exact) return formatPlanName(exact) + " plan"
    var known = plans[reportKey(report)] || plans[report.provider + "|" + (metadata.email || "")]
      || plans[report.provider + "|*"]
    if (known && known.plan) return known.plan + " plan"
    if (known && known.access) return known.access
    if (report.noUsage) return report.credentialType === "api_key" ? "API key" : "Subscription"
    if (String(metadata.endpoint || "").indexOf("/oauth/") >= 0) return "Subscription"
    return ""
  }

  // Clear drag state before reordering: the reorder moves the very account
  // card whose mouse handler is calling this.
  function finishDrag(commit) {
    var key = dragKey
    var period = dragPeriod
    var index = dropIndex
    dragKey = ""
    dragPeriod = ""
    dropIndex = -1
    if (commit && key !== "" && period !== "" && index >= 0)
      Qt.callLater(function() { root.moveReportWithinPeriod(period, key, index) })
  }

  // Reorder one account inside its period. The panel order is global, so the
  // period's subsequence is reordered in place while every other account
  // keeps its position.
  function moveReportWithinPeriod(periodKey, key, toIndex) {
    var members = visiblePeriodAccounts(periodKey)
    var from = members.indexOf(key)
    if (from < 0 || toIndex < 0) return
    // dropIndex is an insertion slot in the un-removed list: dropping back
    // on the dragged card's own slot(s) is a no-op.
    if (toIndex === from || toIndex === from + 1) return
    members.splice(from, 1)
    members.splice(toIndex > from ? toIndex - 1 : toIndex, 0, key)
    var order = []
    var queue = members.slice()
    var current = displayReports.map(reportKey)
    for (var i = 0; i < current.length; i++)
      order.push(members.indexOf(current[i]) >= 0 ? queue.shift() : current[i])
    // Keep positions of accounts that are not logged in right now.
    for (var j = 0; j < savedOrder.length; j++)
      if (order.indexOf(savedOrder[j]) < 0) order.push(savedOrder[j])
    savedOrder = order
    saveState()
  }

  function loadState(text) {
    try {
      var state = JSON.parse(String(text || "{}"))
      savedOrder = Array.isArray(state.order) ? state.order : []
      collapsed = state.collapsed && typeof state.collapsed === "object" ? state.collapsed : ({})
    } catch (error) {
      savedOrder = []
      collapsed = ({})
    }
  }

  // Mirrors OMP's resolveUsedFraction: explicit fraction > used/limit >
  // percent-unit used > inverted remaining. undefined = no quota to draw.
  function usedFraction(limit) {
    var amount = limit && limit.amount ? limit.amount : {}
    if (amount.usedFraction !== undefined) return Number(amount.usedFraction)
    if (amount.used !== undefined && Number(amount.limit) > 0) return amount.used / amount.limit
    if (amount.unit === "percent" && amount.used !== undefined) return amount.used / 100
    if (amount.remainingFraction !== undefined) return Math.max(0, 1 - amount.remainingFraction)
    return undefined
  }

  function formatQuantity(value, unit) {
    if (unit === "usd") return "$" + Number(value).toFixed(2)
    var formatted = Number(value).toLocaleString(Qt.locale("en_US"), "f", Number(value) % 1 === 0 ? 0 : 1)
    return unit && unit !== "unknown" ? formatted + " " + unit : formatted
  }

  // Absolute figures: "$8.40 of $20.00" beside a bar, or the whole reading
  // ("$12.34 used", "$5.00 left") when there is no allowance to draw a bar from.
  function amountText(limit) {
    var amount = limit && limit.amount ? limit.amount : {}
    if (amount.unit === "percent") return ""
    if (amount.used !== undefined && Number(amount.limit) > 0)
      return formatQuantity(amount.used, amount.unit) + " of " + formatQuantity(amount.limit, amount.unit)
    if (amount.used !== undefined) return formatQuantity(amount.used, amount.unit) + " used"
    if (amount.remaining !== undefined) return formatQuantity(amount.remaining, amount.unit) + " left"
    return ""
  }

  function detailText(limit, hasBar) {
    var parts = []
    var amount = hasBar ? amountText(limit) : ""
    if (amount && !windowExpired(limit)) parts.push(amount)
    var reset = resetText(limit)
    if (reset) parts.push(reset)
    return parts.join(" · ")
  }

  // Providers whose usage endpoint is throttled hard (Anthropic limits
  // /api/oauth/usage per IP). They are polled live at most once a minute,
  // backing off while they answer with a rate limit; OMP's own recorded
  // usage (from normal model responses) fills the gap.
  readonly property var slowProviders: ({ "anthropic": true })
  readonly property int slowIntervalMs: 60000
  readonly property int slowMaxBackoffMs: 15 * 60000
  // Full `omp usage --json` pass: discovers accounts (including ones
  // without usage) and doubles as a slow-provider poll.
  readonly property int discoveryIntervalMs: 15 * 60000

  function refresh() {
    if (usageProcess.running) return
    var now = Date.now()
    var allSlowDue = true
    var providers = []
    for (var i = 0; i < knownProviders.length; i++) {
      var id = knownProviders[i]
      if (!slowProviders[id]) providers.push(id)
      else if (now >= Number(slowNextAt[id] || 0)) providers.push(id)
      else allSlowDue = false
    }
    // Rediscover periodically, but never while a slow provider is backing off.
    var full = lastFullAt === 0 || (allSlowDue && now - lastFullAt >= discoveryIntervalMs)
    pending = { full: full, providers: full ? knownProviders.slice() : providers, startedAt: now }
    usageProcess.command = ["bash", "-c", batchScript, "omp-usage"].concat(full ? ["--all"] : providers)
    usageProcess.running = true
  }

  // A full pass replaces the account list, so logins and logouts show up
  // (and removed accounts disappear) without waiting for periodic discovery.
  function rediscover() {
    if (usageProcess.running) {
      rediscoverQueued = true
      return
    }
    rediscoverQueued = false
    lastFullAt = 0
    refresh()
  }

  function checkAccounts(text) {
    var out = String(text || "")
    // No "ok" line: store missing, locked, or sqlite3 failed. Keep the current view.
    if (out.indexOf("ok") !== 0) return
    var signature = out.slice(2).trim()
    if (signature === accountsSignature) return
    var first = accountsSignature === null
    accountsSignature = signature
    if (!first) rediscover()
  }

  // Runs the requested OMP calls in parallel plus the local history read,
  // emitting each JSON document followed by an ASCII record separator.
  readonly property string batchScript: "tmp=$(mktemp -d); trap 'rm -rf \"$tmp\"' EXIT\n"
    + "if [ \"$1\" = --all ]; then omp usage --json > \"$tmp/0\" &\n"
    + "else i=0; for p in \"$@\"; do i=$((i+1)); omp usage --json --provider \"$p\" > \"$tmp/$i\" & done; fi\n"
    + "omp usage --history --json --days 1 > \"$tmp/h\" &\n"
    + "wait\n"
    + "for f in \"$tmp\"/*; do cat \"$f\"; printf '\\036'; done\n"

  function formatDuration(ms) {
    if (!(ms > 0)) return "now"
    var minutes = Math.floor(ms / 60000)
    var hours = Math.floor(minutes / 60)
    var days = Math.floor(hours / 24)
    if (days > 0) return days + "d " + (hours % 24) + "h"
    if (hours > 0) return hours + "h " + (minutes % 60) + "m"
    return Math.max(1, minutes) + "m"
  }

  function resetText(limit) {
    if (windowExpired(limit)) return "Window reset · waiting for fresh data"
    var resetAt = Number(limit && limit.window && limit.window.resetsAt)
    return resetAt > 0 ? "Resets in " + formatDuration(resetAt - nowMs) : ""
  }

  // OMP falls back to its last cached report (however old) when a provider
  // rate-limits the usage endpoint. A window whose reset has passed carries no
  // valid usage figure.
  function windowExpired(limit) {
    var resetAt = Number(limit && limit.window && limit.window.resetsAt)
    return resetAt > 0 && resetAt <= nowMs
  }

  function reportKey(report) {
    var metadata = report && report.metadata ? report.metadata : {}
    return String(report && report.provider) + "|" + String(metadata.accountId || metadata.email || "")
  }

  // Logged-in accounts OMP has no usage endpoint (or no data) for.
  function accountWithoutUsage(account) {
    return {
      provider: account.provider,
      noUsage: true,
      credentialType: account.type,
      metadata: { email: account.email, accountId: account.accountId },
      limits: []
    }
  }

  // Latest recorded snapshot per account limit from `omp usage --history`.
  function indexHistory(entries) {
    var latest = {}
    for (var i = 0; i < entries.length; i++) {
      var e = entries[i]
      var key = e.provider + "|" + (e.accountId || e.email || "") + "|" + e.limitId
      if (!latest[key] || latest[key].recordedAt < e.recordedAt) latest[key] = e
    }
    return latest
  }

  // Replace limits in a report that OMP has recorded more recently than the
  // report itself was fetched (e.g. a rate-limited provider's cached report).
  function withHistory(report) {
    if (!report || report.noUsage || !Array.isArray(report.limits)) return report
    var fetchedAt = Number(report.fetchedAt) || 0
    var asOf = fetchedAt
    var prefix = reportKey(report) + "|"
    var limits = []
    for (var i = 0; i < report.limits.length; i++) {
      var limit = report.limits[i]
      var h = history[prefix + limit.id]
      if (!h || !(h.recordedAt > fetchedAt) || h.usedFraction === undefined || h.usedFraction === null) {
        limits.push(limit)
        continue
      }
      var amount = Object.assign({}, limit.amount, {
        usedFraction: h.usedFraction,
        remainingFraction: Math.max(0, 1 - h.usedFraction)
      })
      if (Number(amount.limit) > 0) {
        amount.used = amount.limit * h.usedFraction
        amount.remaining = Math.max(0, amount.limit - amount.used)
      } else if (amount.unit === "percent") {
        amount.used = h.usedFraction * 100
      }
      var windowInfo = Object.assign({}, limit.window)
      if (h.resetsAt) windowInfo.resetsAt = h.resetsAt
      else delete windowInfo.resetsAt
      limits.push(Object.assign({}, limit, { amount: amount, window: windowInfo }))
      asOf = Math.max(asOf, h.recordedAt)
    }
    return Object.assign({}, report, { limits: limits, asOf: asOf })
  }

  function staleText(report) {
    var at = Number(report && (report.asOf || report.fetchedAt))
    if (!(at > 0)) return ""
    var age = nowMs - at
    if (age >= 2 * 3600000) return "Provider unreachable · last update " + formatDuration(age) + " ago"
    // Only once a scheduled poll has been missed; data this old is expected otherwise.
    if (age >= refreshIntervalSec * 1000 + 60000) return "Updated " + formatDuration(age) + " ago"
    return ""
  }

  function staleUrgent(report) {
    var at = Number(report && (report.asOf || report.fetchedAt))
    return at > 0 && nowMs - at >= 2 * 3600000
  }

  function limitTitle(limit) {
    var title = String(limit && (limit.label || limit.window && limit.window.label) || "Usage")
    var scope = limit && limit.scope ? limit.scope : null
    if (scope && scope.modelId) title += " · " + scope.modelId
    return title
  }

  function parseBatch(text) {
    var request = pending || { full: true, providers: [], startedAt: Date.now() }
    pending = null
    var docs = String(text || "").split("\u001e")
    var incoming = []
    var sawReports = false
    for (var d = 0; d < docs.length; d++) {
      var chunk = docs[d].trim()
      if (chunk === "") continue
      var parsed
      try {
        parsed = JSON.parse(chunk)
      } catch (error) {
        console.warn("omp-usage", error)
        continue
      }
      if (Array.isArray(parsed.entries)) {
        history = indexHistory(parsed.entries)
        continue
      }
      sawReports = true
      if (Array.isArray(parsed.reports)) incoming = incoming.concat(parsed.reports)
      var unreported = Array.isArray(parsed.accountsWithoutUsage) ? parsed.accountsWithoutUsage : []
      for (var k = 0; k < unreported.length; k++) incoming.push(accountWithoutUsage(unreported[k]))
    }
    nowMs = Date.now()
    if (!sawReports && (request.full || request.providers.length > 0)) {
      errorText = "Could not read OMP usage data"
      return
    }

    // Never replace a newer report with an older cached one.
    var previous = {}
    for (var i = 0; i < reports.length; i++) previous[reportKey(reports[i])] = reports[i]
    var incomingKeys = {}
    var merged = []
    for (var j = 0; j < incoming.length; j++) {
      var key = reportKey(incoming[j])
      var known = previous[key]
      incomingKeys[key] = true
      merged.push(known && !known.noUsage && Number(known.fetchedAt) > Number(incoming[j].fetchedAt) ? known : incoming[j])
    }
    // A partial pass only covers some providers; keep everything else.
    if (!request.full)
      for (var p = 0; p < reports.length; p++)
        if (!incomingKeys[reportKey(reports[p])]) merged.push(reports[p])

    if (request.full) {
      lastFullAt = request.startedAt
      var seen = {}
      var ids = []
      for (var m = 0; m < merged.length; m++)
        if (!merged[m].noUsage && !seen[merged[m].provider]) { seen[merged[m].provider] = true; ids.push(merged[m].provider) }
      knownProviders = ids
    }
    scheduleSlowProviders(request, incoming)

    // Keep a stable account order across partial passes.
    var order = {}
    for (var o = 0; o < reports.length; o++) order[reportKey(reports[o])] = o
    merged.sort(function(a, b) {
      var ia = order[reportKey(a)], ib = order[reportKey(b)]
      return (ia === undefined ? 1e9 : ia) - (ib === undefined ? 1e9 : ib)
    })
    reports = merged
    errorText = ""
  }

  // A slow provider that returned a report fetched during this pass is
  // healthy; one that handed back an older cached report is rate-limited.
  function scheduleSlowProviders(request, incoming) {
    var next = Object.assign({}, slowNextAt)
    var backoff = Object.assign({}, slowBackoffMs)
    var polled = request.full ? knownProviders : request.providers
    for (var i = 0; i < polled.length; i++) {
      var id = polled[i]
      if (!slowProviders[id]) continue
      var fresh = false
      for (var j = 0; j < incoming.length; j++)
        if (incoming[j].provider === id && Number(incoming[j].fetchedAt) >= request.startedAt - 5000) fresh = true
      backoff[id] = fresh ? slowIntervalMs : Math.min(slowMaxBackoffMs, Math.max(slowIntervalMs, Number(backoff[id] || 0)) * 2)
      next[id] = Date.now() + backoff[id]
    }
    slowNextAt = next
    slowBackoffMs = backoff
  }

  // Short model name for compact badges: "Claude/GPT", "Gemini", "Claude", etc.
  function shortModelName(label) {
    var s = String(label || "")
    if (s.indexOf("Claude") >= 0 && s.indexOf("GPT") >= 0) return "Claude/GPT"
    if (s.indexOf("Claude") >= 0) return "Claude"
    if (s.indexOf("Gemini") >= 0) return "Gemini"
    if (s.indexOf("Codex") >= 0) return "Codex"
    return s.split("·")[0].split("(")[0].trim().slice(0, 10)
  }

  // Provider header summary: "5 accounts · 2 active" or "5 accounts · all exhausted".
  function providerSummary(group) {
    if (!group) return ""
    var uniqueAccounts = {}
    var activeAccounts = {}
    var periods = group.periods || []
    for (var p = 0; p < periods.length; p++) {
      var accts = periods[p].accounts || []
      for (var a = 0; a < accts.length; a++) {
        var key = accts[a].key
        uniqueAccounts[key] = true
        if (!accountAlarming(accts[a])) activeAccounts[key] = true
      }
    }
    var total = Object.keys(uniqueAccounts).length
    var active = Object.keys(activeAccounts).length
    var countText = total + (total === 1 ? " account" : " accounts")
    if (total === 0) return ""
    if (active === 0) return countText + " · all exhausted"
    if (active === total) return countText + " · all active"
    return countText + " · " + active + " active"
  }

  function providerAlarming(group) {
    if (!group) return false
    var periods = group.periods || []
    var anyActive = false
    var anyAccount = false
    for (var p = 0; p < periods.length; p++) {
      var accts = periods[p].accounts || []
      for (var a = 0; a < accts.length; a++) {
        anyAccount = true
        if (!accountAlarming(accts[a])) anyActive = true
      }
    }
    return anyAccount && !anyActive
  }

  // Period header summary: "2/5 active · Resets in 17h 30m" or "all 2 active · Resets in 4h".
  function periodSummary(period) {
    if (!period) return ""
    var accounts = period.accounts || []
    var total = accounts.length
    if (total === 0) return ""
    var active = 0
    var resetAt = 0
    for (var i = 0; i < total; i++) {
      if (!accountAlarming(accounts[i])) active++
      var limits = accounts[i].limits || []
      for (var j = 0; j < limits.length; j++) {
        if (windowExpired(limits[j])) continue
        var at = Number(limits[j].window && limits[j].window.resetsAt) || 0
        if (at > 0 && (resetAt === 0 || at < resetAt)) resetAt = at
      }
    }
    var status = active === 0 ? "all exhausted" : (active === total ? "all " + total + " active" : active + "/" + total + " active")
    var parts = [status]
    if (resetAt > 0) parts.push("Resets in " + formatDuration(resetAt - nowMs))
    return parts.join(" · ")
  }

  function periodAlarming(period) {
    if (!period) return false
    var accounts = period.accounts || []
    if (accounts.length === 0) return false
    for (var i = 0; i < accounts.length; i++) {
      if (!accountAlarming(accounts[i])) return false
    }
    return true
  }

  function accountCollapseKey(periodKey, entryKey) { return "a|" + periodKey + "|" + entryKey }

  // Account card summary:
  // - single limit: "70% left" (or "exhausted")
  // - mixed (1 available, others exhausted): "Gemini 70% left"
  // - all exhausted: "exhausted"
  // - multiple available: "Claude/GPT 80% · Gemini 60% left"
  function accountSummary(entry) {
    if (!entry || entry.noUsage) return ""
    var limits = aggregateLimits(entry.limits || [])
    if (limits.length === 0) return ""
    var avail = []
    var exhCount = 0
    for (var i = 0; i < limits.length; i++) {
      var l = limits[i]
      if (windowExpired(l)) continue
      var u = usedFraction(l)
      if (u === undefined || isNaN(u)) continue
      var lbl = shortModelName(l.label || (l.window && l.window.label))
      var left = Math.max(0, 1 - u)
      if (u >= 0.999) {
        exhCount++
      } else {
        avail.push({ label: lbl, leftPct: Math.round(left * 100) })
      }
    }
    if (avail.length === 0) return "exhausted"
    if (avail.length === 1 && exhCount === 0) return avail[0].leftPct + "% left"
    if (avail.length === 1 && exhCount > 0) return avail[0].label + " " + avail[0].leftPct + "% left"
    var parts = []
    for (var j = 0; j < avail.length; j++) {
      parts.push(avail[j].label + " " + avail[j].leftPct + "%")
    }
    return parts.join(" · ") + " left"
  }

  function accountAlarming(entry) {
    if (!entry || entry.noUsage) return false
    var limits = aggregateLimits(entry.limits || [])
    if (limits.length === 0) return false
    var anyAvailable = false
    var anySafe = false
    for (var i = 0; i < limits.length; i++) {
      var l = limits[i]
      if (windowExpired(l)) continue
      var u = usedFraction(l)
      if (u === undefined || isNaN(u)) continue
      if (u < 0.999) anyAvailable = true
      if (u < 0.9) anySafe = true
    }
    if (!anyAvailable) return true
    return !anySafe
  }

  // Same model label repeated inside one period (e.g. two "Gemini" rows on
  // one account): aggregate the identical figures into one LimitRow so the
  // card shows one bar per quota instead of one per raw limit row.
  function aggregateLimits(limits) {
    var result = []
    var indexByLabel = {}
    for (var i = 0; i < (limits || []).length; i++) {
      var l = limits[i]
      var label = String((l && (l.label || (l.window && l.window.label))) || "Usage")
      var at = Number(l && l.window && l.window.resetsAt) || 0
      if (indexByLabel[label] === undefined) {
        indexByLabel[label] = result.length
        result.push(l)
        continue
      }
      var keep = result[indexByLabel[label]]
      var keepAt = Number(keep && keep.window && keep.window.resetsAt) || 0
      if (at > 0 && (keepAt === 0 || at < keepAt)) result[indexByLabel[label]] = l
    }
    return result
  }

  // Plans change rarely: look them up at start, then at most hourly on open.
  property double plansFetchedAt: 0
  function refreshPlans() {
    if (planProcess.running) return
    plansFetchedAt = Date.now()
    planProcess.running = true
  }

  Component.onCompleted: {
    refresh()
    refreshPlans()
  }
  // Opening the panel is the moment fresh numbers matter: refresh now and
  // start the periodic interval over from here.
  onOpenedChanged: if (opened) {
    nowMs = Date.now()
    refresh()
    usageTimer.restart()
    checkAccountsNow()
    if (nowMs - plansFetchedAt > 3600000) refreshPlans()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Usage is polled only at the configured pace (default 5 minutes), open or
  // closed. Slow providers still join a pass only when their schedule is due.
  Timer {
    id: usageTimer
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  // Open: keep "Resets in" / "Updated ago" ticking. Clock only, no processes.
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  Process {
    id: usageProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.parseBatch(text)
        if (root.rediscoverQueued) Qt.callLater(root.rediscover)
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("omp-usage", text.trim())
    }
  }

  Process {
    id: planProcess
    command: ["python3", Qt.resolvedUrl("plans.py").toString().replace(/^file:\/\//, "")]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(String(text || "{}"))
          if (parsed && typeof parsed === "object") root.plans = parsed
        } catch (error) {
          console.warn("omp-usage plans", error)
        }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("omp-usage plans", text.trim())
    }
  }

  // Enabled credentials in OMP's store, read-only. Credential rows change on
  // login and logout (and token refresh, which leaves this signature alone).
  Process {
    id: accountsProcess
    command: ["sqlite3", "-readonly", "-noheader", "-cmd", ".timeout 1000", root.credentialStore,
      "select 'ok' || coalesce(group_concat(id || ':' || provider || ':' || credential_type || ':' || coalesce(identity_key, ''), ' '), '')"
      + " from (select id, provider, credential_type, identity_key from auth_credentials where disabled_cause is null order by id)"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.checkAccounts(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("omp-usage accounts", text.trim())
    }
  }

  function checkAccountsNow() {
    if (!accountsProcess.running) accountsProcess.running = true
  }

  // One tiny read-only query; logins and logouts show up within this interval.
  Timer {
    interval: 30000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.checkAccountsNow()
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadState(text())
    onLoadFailed: root.loadState("{}")
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Dual-SIM style signal: top row bars = first account, bottom row dots =
    // second account; more lit = more usage left. π when nothing reports usage.
    text: root.meters.length === 0 ? "π" : ""
    iconComponent: root.meters.length === 0 ? null : signalIcon
    // 17px canvas centers on whole pixels in the 27px slot, keeping bars crisp.
    opticalSize: 17
    active: root.alarming
    tooltipText: root.meterTooltip
    onPressed: function(buttonCode) { root.toggle() }
  }

  Component {
    id: signalIcon
    Item {
      id: signal
      readonly property color lit: button.foreground
      readonly property color dimmed: Qt.rgba(lit.r, lit.g, lit.b, 0.28)
      readonly property var primary: root.meters.length > 0 ? root.meters[0] : null
      readonly property var secondary: root.meters.length > 1 ? root.meters[1] : null
      readonly property color primaryColor: primary && (primary.alarming || root.hiddenAlarm) ? button.activeColor : lit
      readonly property color secondaryColor: secondary && (secondary.alarming || root.hiddenAlarm) ? button.activeColor : lit

      // Laid out in physical pixels (u) so fractional display scaling keeps
      // segments even: 3px wide, 1px apart, bars 3/5/7/9px tall, 3px squares,
      // 3px between rows, 1px corner radius. Centered in the icon canvas.
      // Window ratio, not Screen: Wayland reports Screen at the rounded-up
      // integer scale (2 on a 1.25x output).
      readonly property real u: 1 / Math.max(1, Window.window ? Window.window.devicePixelRatio : 1)
      readonly property real contentWidth: 15 * u
      readonly property real contentHeight: (secondary ? 15 : 9) * u
      readonly property real originX: (width - contentWidth) / 2
      readonly property real originY: (height - contentHeight) / 2

      Repeater {
        model: 4
        Rectangle {
          required property int index
          x: signal.originX + index * 4 * signal.u
          width: 3 * signal.u
          height: (3 + index * 2) * signal.u
          y: signal.originY + 9 * signal.u - height
          radius: signal.u
          color: signal.primary && index < signal.primary.level ? signal.primaryColor : signal.dimmed
        }
      }

      Repeater {
        model: signal.secondary ? 4 : 0
        Rectangle {
          required property int index
          x: signal.originX + index * 4 * signal.u
          y: signal.originY + 12 * signal.u
          width: 3 * signal.u
          height: 3 * signal.u
          radius: signal.u
          color: index < signal.secondary.level ? signal.secondaryColor : signal.dimmed
        }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) panelFlick.contentY = Math.max(0, Math.min(panelFlick.contentHeight - panelFlick.height,
          panelFlick.contentY + dy * Style.space(56)))
      }
      onActivateRequested: root.refresh()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r" || text === "R") root.refresh()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        // Where a dragged account will land (inside its period list).
        Rectangle {
          id: dropLine
          z: 2
          visible: root.dragKey !== "" && root.dropIndex >= 0
          x: root.accountIndent
          width: panelFlick.width - root.accountIndent
          height: Math.max(2, Style.space(2))
          radius: height / 2
          color: Color.accent
          y: root.dropY - height / 2
        }


        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "OMP Usage"
            meta: "Oh My Pi · " + root.groups.length + (root.groups.length === 1 ? " provider · " : " providers · ") + root.displayReports.length + (root.displayReports.length === 1 ? " account" : " accounts")
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: "π"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                font.bold: true
              }
            }
          }

          // Keyed by provider: delegates survive data refreshes (a plain
          // JS-array model would rebuild them all, killing any drag).
          Repeater {
            id: sectionRepeater
            model: sectionModel
            ProviderGroup {
              required property string key
              width: column.width
              provider: root.groupByKey(key)
            }
          }

          Text {
            visible: root.reports.length === 0 && root.errorText === ""
            width: parent.width
            text: "No accounts logged in to Oh My Pi. Run omp and use /login."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.errorText !== ""
            width: parent.width
            text: root.errorText
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            text: "Updates on open and every " + root.formatDuration(root.refreshIntervalSec * 1000) + " · drag an account within its period to reorder"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }

  // Clickable row shared by all three grouping levels: chevron,
  // title, optional email, and a dim summary on the right. Clicking
  // toggles; dragging only exists on the account row.
  component GroupHeader: Item {
    id: header
    property string chevron: "▾"
    property string title: ""
    property string email: ""
    property string summary: ""
    property bool alarming: false
    property string iconSource: ""
    property string initial: ""
    property real indent: 0
    signal pressed
    width: parent ? parent.width : 0
    implicitHeight: Math.max(titleLine.implicitHeight, Math.max(iconBox.height, chev.implicitHeight))
    Text {
      id: chev
      anchors.left: parent.left
      anchors.leftMargin: header.indent
      anchors.verticalCenter: parent.verticalCenter
      width: root.chevW
      text: header.chevron
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      horizontalAlignment: Text.AlignHCenter
    }
    Item {
      id: iconBox
      anchors.left: chev.right
      anchors.verticalCenter: parent.verticalCenter
      width: header.iconSource !== "" || header.initial !== "" ? Style.font.body * 1.25 : 0
      height: width
      Image {
        anchors.fill: parent
        visible: header.iconSource !== ""
        source: header.iconSource
        sourceSize.width: parent.width * 2
        sourceSize.height: parent.height * 2
        fillMode: Image.PreserveAspectFit
      }
      Text {
        anchors.centerIn: parent
        visible: header.iconSource === "" && header.initial !== ""
        text: header.initial
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }
    }
    Column {
      id: titleLine
      anchors.left: iconBox.right
      anchors.leftMargin: Style.spacing.sm
      anchors.right: summaryText.left
      anchors.rightMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      Text {
        width: parent.width
        text: header.title
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
      }
      Text {
        visible: header.email !== ""
        width: parent.width
        text: header.email
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideMiddle
      }
    }
    Text {
      id: summaryText
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: header.summary
      color: header.alarming ? root.urgent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideLeft
    }
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: header.pressed()
    }
  }

  // One provider: header + its quota periods.
  component ProviderGroup: Column {
    id: providerGroup
    property var provider: null
    readonly property string providerId: provider ? String(provider.provider) : ""
    readonly property string groupKey: "g|" + providerId
    readonly property string iconSource: root.providerIcon(providerId)
    readonly property bool collapsed: root.isCollapsed(groupKey)
    spacing: Style.space(10)
    PanelSeparator { width: parent.width; foreground: root.foreground }
    GroupHeader {
      width: parent.width
      chevron: providerGroup.collapsed ? "▸" : "▾"
      title: root.providerName(providerGroup.providerId)
      summary: root.providerSummary(providerGroup.provider)
      alarming: root.providerAlarming(providerGroup.provider)
      iconSource: providerGroup.iconSource
      initial: providerGroup.iconSource === "" ? root.providerName(providerGroup.providerId).charAt(0) : ""
      onPressed: root.toggleGroup(providerGroup.groupKey)
    }
    Column {
      visible: !providerGroup.collapsed
      width: parent.width
      spacing: Style.space(10)
      Repeater {
        model: providerGroup.provider ? providerGroup.provider.periods : []
        PeriodGroup {
          required property var modelData
          width: parent.width
          providerId: providerGroup.providerId
          period: modelData
        }
      }
    }
  }

  // One quota period ("Weekly", "5 Hour", …) inside a provider.
  component PeriodGroup: Column {
    id: periodGroup
    property string providerId: ""
    property var period: null
    readonly property string periodKey: period ? String(period.key) : ""
    readonly property bool collapsed: root.isCollapsed(periodKey)
    readonly property bool alarming: root.periodAlarming(period)
    spacing: Style.space(8)
    Item {
      width: parent.width
      height: Style.space(4)
    }
    GroupHeader {
      width: parent.width
      indent: root.periodIndent - root.chevW
      chevron: periodGroup.collapsed ? "▸" : "▾"
      title: periodGroup.period ? String(periodGroup.period.label) : ""
      summary: root.periodSummary(periodGroup.period)
      alarming: periodGroup.alarming
      onPressed: root.toggleGroup(periodGroup.periodKey)
    }
    Column {
      id: accountList
      visible: !periodGroup.collapsed
      width: parent.width
      spacing: Style.space(8)
      Repeater {
        model: periodGroup.period ? periodGroup.period.accounts : []
        AccountCard {
          required property var modelData
          required property int index
          width: accountList.width
          providerId: periodGroup.providerId
          periodKey: periodGroup.periodKey
          entry: modelData
          entryIndex: index
          entryCount: periodGroup.period ? periodGroup.period.accounts.length : 0
        }
      }
    }
  }

  // One account inside a period: email + plan + that period's limit rows.
  // Draggable within its own period list to reorder.
  component AccountCard: Column {
    id: card
    property string providerId: ""
    property string periodKey: ""
    property var entry: null
    property int entryIndex: 0
    property int entryCount: 1
    readonly property string entryKey: entry ? String(entry.key) : ""
    readonly property string collapseKey: root.accountCollapseKey(card.periodKey, card.entryKey)
    readonly property bool collapsed: root.isCollapsed(card.collapseKey)
    readonly property bool dragging: root.dragKey !== "" && root.dragKey === card.entryKey && root.dragPeriod === card.periodKey
    // Follows the pointer while dragging; the drop line shows the landing spot.
    property real dragOffset: 0
    z: dragging ? 10 : 0
    opacity: dragging ? 0.6 : 1
    transform: Translate { y: card.dragging ? card.dragOffset : 0 }
    readonly property string summary: root.accountSummary(card.entry)
    readonly property bool alarming: root.accountAlarming(card.entry)
    spacing: Style.space(8)
    Item {
      width: parent.width
      implicitHeight: Math.max(headerRow.implicitHeight, Style.font.body * 1.25)
      Item {
        id: headerRow
        anchors.left: parent.left
        anchors.leftMargin: root.accountIndent - root.chevW
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        implicitHeight: Math.max(cardTitle.implicitHeight, cardChev.implicitHeight)
        Text {
          id: cardChev
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: root.chevW
          text: card.collapsed ? "▸" : "▾"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          horizontalAlignment: Text.AlignHCenter
        }
        Column {
          id: cardTitle
          anchors.left: cardChev.right
          anchors.leftMargin: Style.spacing.sm
          anchors.right: cardSummary.left
          anchors.rightMargin: Style.spacing.sm
          anchors.verticalCenter: parent.verticalCenter
          Text {
            width: parent.width
            text: card.entry && card.entry.email ? card.entry.email : (card.entry ? root.shortAccount(card.entry.report) : "")
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideMiddle
          }
          Text {
            id: cardEmail
            visible: text !== ""
            width: parent.width
            text: card.entry ? root.planText(card.entry.report) : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideLeft
          }
        }
        Text {
          id: cardSummary
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: card.summary
          color: card.alarming ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
        MouseArea {
          anchors.fill: parent
          preventStealing: true
          cursorShape: card.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor
          property real pressY: 0
          property bool held: false
          onPressed: function(mouse) {
            held = true
            pressY = mapToItem(column, mouse.x, mouse.y).y
            card.dragOffset = 0
          }
          onPositionChanged: function(mouse) {
            if (!held) return
            var y = mapToItem(column, mouse.x, mouse.y).y
            if (!card.dragging) {
              if (Math.abs(y - pressY) < Style.space(4)) return
              root.dragKey = card.entryKey
              root.dragPeriod = card.periodKey
            }
            card.dragOffset = y - pressY
            // Pointer minus the press offset inside the card gives the card's
            // top; each gap between cards is one insertion index.
            var step = Math.max(1, card.height + Style.space(8))
            var cardTop = card.mapToItem(column, 0, 0).y
            var topY = cardTop + (y - pressY)
            var firstTop = cardTop - card.entryIndex * step
            root.dropIndex = Math.max(0, Math.min(card.entryCount, Math.round((topY - firstTop) / step)))
            root.dropY = firstTop + root.dropIndex * step
          }
          onReleased: function(mouse) {
            held = false
            if (card.dragging) root.finishDrag(true)
            else if (Math.abs(mapToItem(column, mouse.x, mouse.y).y - pressY) < Style.space(4)) root.toggleGroup(card.collapseKey)
          }
          onCanceled: {
            held = false
            root.finishDrag(false)
          }
        }
      }
    }
    Column {
      visible: !card.collapsed
      width: parent.width
      spacing: Style.space(6)
      Item {
        width: parent.width
        height: 0
      }
      Repeater {
        model: card.entry ? root.aggregateLimits(card.entry.limits) : []
        LimitRow {
          required property var modelData
          width: card.width - root.accountIndent
          x: root.accountIndent
          limit: modelData
        }
      }
      Text {
        visible: !!(card.entry && card.entry.noUsage)
        width: parent.width - root.accountIndent
        x: root.accountIndent
        text: "Logged in, but this provider doesn't report usage to Oh My Pi."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
      Text {
        visible: !!(card.entry && card.entry.resetCount > 0)
        width: parent.width - root.accountIndent
        x: root.accountIndent
        text: card.entry.resetCount + " saved reset" + (card.entry.resetCount === 1 ? "" : "s")
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
      Text {
        visible: text !== ""
        width: parent.width - root.accountIndent
        x: root.accountIndent
        text: card.entry ? root.staleText(card.entry.report) : ""
        color: card.entry ? (root.staleUrgent(card.entry.report) ? root.urgent : root.dim) : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
  }


  component LimitRow: Column {
    id: limitRow
    property var limit: null
    readonly property bool expired: root.windowExpired(limit)
    readonly property var rawFraction: root.usedFraction(limit)
    readonly property bool hasBar: rawFraction !== undefined && !isNaN(rawFraction)
    readonly property real fraction: expired || !hasBar ? 0 : Math.max(0, Math.min(1, rawFraction))
    readonly property bool alarming: fraction >= 0.9
    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(label.implicitHeight, value.implicitHeight)
      Text {
        id: label
        anchors.left: parent.left
        anchors.right: value.left
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
        text: root.limitTitle(limitRow.limit)
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }
      Text {
        id: value
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: limitRow.expired ? "—" : limitRow.hasBar ? Math.round(limitRow.fraction * 100) + "%" : root.amountText(limitRow.limit)
        color: limitRow.alarming ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    Rectangle {
      visible: limitRow.hasBar
      width: parent.width
      height: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))
      radius: height / 2
      color: root.track
      Rectangle {
        width: parent.width * limitRow.fraction
        height: parent.height
        radius: height / 2
        color: limitRow.alarming ? root.urgent : Color.accent
      }
    }

    Text {
      visible: text !== ""
      width: parent.width
      text: root.detailText(limitRow.limit, limitRow.hasBar)
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
