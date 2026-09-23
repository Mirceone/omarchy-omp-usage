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

  readonly property var displayReports: reports.map(withHistory)

  readonly property bool alarming: {
    for (var r = 0; r < displayReports.length; r++) {
      var limits = displayReports[r].limits || []
      for (var i = 0; i < limits.length; i++)
        if (!windowExpired(limits[i]) && Number(usedFraction(limits[i])) >= 0.9) return true
    }
    return false
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

  // Only states what the report actually proves; never guesses "API".
  function accountText(report) {
    if (!report) return ""
    if (report.noUsage) return report.credentialType === "api_key" ? "API key" : "Subscription"
    var metadata = report.metadata || {}
    var plan = String(metadata.planType || "")
    if (plan) return plan[0].toUpperCase() + plan.slice(1) + " plan"
    if (String(metadata.endpoint || "").indexOf("/oauth/") >= 0) return "Subscription"
    return String(metadata.email || "")
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
    if (age >= 90000) return "Updated " + formatDuration(age) + " ago"
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

  Component.onCompleted: refresh()
  onOpenedChanged: if (opened) {
    nowMs = Date.now()
    refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Closed: keep the bar icon's alarm state current at the configured pace.
  Timer {
    interval: root.refreshIntervalSec * 1000
    running: !root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  // Open: live view every 3s for providers that tolerate it; slow providers
  // join a tick only when their own schedule is due. refresh() skips a tick
  // while a pass is still running.
  Timer {
    interval: 3000
    running: root.opened
    repeat: true
    onTriggered: {
      root.nowMs = Date.now()
      root.refresh()
    }
  }

  Process {
    id: usageProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseBatch(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("omp-usage", text.trim())
    }
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
    // The stock Agents widget uses a glyph through BarIconButton. π is the
    // Oh My Pi mark here, avoiding a theme-dependent raster asset.
    text: "π"
    active: root.alarming
    tooltipText: "OMP Usage"
    onPressed: function(buttonCode) { root.toggle() }
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

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "OMP Usage"
            meta: root.reports.length === 1 ? "Oh My Pi · 1 account" : "Oh My Pi · " + root.reports.length + " accounts"
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

          Repeater {
            model: root.displayReports
            ProviderSection {
              // Index into the JS array: modelData would be converted to a
              // QVariantMap whose nested lists fail Array.isArray.
              required property int index
              width: parent.width
              report: root.displayReports[index]
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
            text: "Live · updates every 3s · Esc close"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }

  component ProviderSection: Column {
    id: section
    property var report: null
    readonly property string iconSource: report ? root.providerIcon(report.provider) : ""
    readonly property int resetCount: report && report.resetCredits ? Number(report.resetCredits.availableCount) || 0 : 0
    spacing: Style.space(10)

    PanelSeparator { width: parent.width; foreground: root.foreground }

    Item {
      width: parent.width
      implicitHeight: Math.max(name.implicitHeight, icon.height)
      Item {
        id: icon
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Style.font.body * 1.25
        height: width
        Image {
          anchors.fill: parent
          visible: section.iconSource !== ""
          source: section.iconSource
          sourceSize.width: parent.width * 2
          sourceSize.height: parent.height * 2
          fillMode: Image.PreserveAspectFit
        }
        // Providers without a bundled logo get their initial instead.
        Text {
          anchors.centerIn: parent
          visible: section.iconSource === ""
          text: section.report ? root.providerName(section.report.provider).charAt(0) : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }
      }
      Text {
        id: name
        anchors.left: icon.right
        anchors.leftMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
        text: section.report ? root.providerName(section.report.provider) : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }
      Text {
        anchors.left: name.right
        anchors.leftMargin: Style.spacing.sm
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: root.accountText(section.report)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignRight
        elide: Text.ElideLeft
      }
    }

    Repeater {
      model: section.report && Array.isArray(section.report.limits) ? section.report.limits : []
      LimitRow {
        required property var modelData
        width: section.width
        limit: modelData
      }
    }

    Text {
      visible: !!(section.report && section.report.noUsage)
      width: parent.width
      text: section.report ? "Logged in, but " + root.providerName(section.report.provider) + " doesn't report usage to Oh My Pi." : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Text {
      visible: section.resetCount > 0
      width: parent.width
      text: section.resetCount + " saved reset" + (section.resetCount === 1 ? "" : "s")
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      visible: text !== ""
      width: parent.width
      text: root.staleText(section.report)
      color: root.staleUrgent(section.report) ? root.urgent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
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
