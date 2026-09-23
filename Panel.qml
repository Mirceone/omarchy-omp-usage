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
  property int selectedIndex: 0
  property string errorText: ""
  property double nowMs: Date.now()

  readonly property var provider: reports.length > 0 ? reports[selectedIndex] : null
  readonly property bool alarming: {
    if (!provider || !provider.limits) return false
    for (var i = 0; i < provider.limits.length; i++)
      if (!windowExpired(provider.limits[i]) && Number(usedFraction(provider.limits[i])) >= 0.9) return true
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

  function heroMeta(report) {
    var detail = accountText(report)
    return detail ? "Oh My Pi · " + detail : "Oh My Pi"
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

  function refresh() {
    if (!usageProcess.running) usageProcess.running = true
  }

  function selectProvider(index) {
    if (reports.length === 0) return
    selectedIndex = ((index % reports.length) + reports.length) % reports.length
    panelFlick.contentY = 0
  }

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

  function staleText(report) {
    var fetchedAt = Number(report && report.fetchedAt)
    if (!(fetchedAt > 0) || nowMs - fetchedAt < root.refreshIntervalSec * 2000) return ""
    return "Provider unreachable · last update " + formatDuration(nowMs - fetchedAt) + " ago"
  }

  function limitTitle(limit) {
    var title = String(limit && (limit.label || limit.window && limit.window.label) || "Usage")
    var scope = limit && limit.scope ? limit.scope : null
    if (scope && scope.modelId) title += " · " + scope.modelId
    return title
  }

  function parseUsage(text) {
    var parsed
    try {
      parsed = JSON.parse(String(text || ""))
    } catch (error) {
      errorText = "Could not read OMP usage data"
      console.warn("omp-usage", error)
      return
    }
    var incoming = Array.isArray(parsed.reports) ? parsed.reports.slice() : []
    var unreported = Array.isArray(parsed.accountsWithoutUsage) ? parsed.accountsWithoutUsage : []
    for (var k = 0; k < unreported.length; k++) incoming.push(accountWithoutUsage(unreported[k]))
    // Never replace a newer report with an older cached one.
    var previous = {}
    for (var i = 0; i < reports.length; i++) previous[reportKey(reports[i])] = reports[i]
    var merged = []
    for (var j = 0; j < incoming.length; j++) {
      var known = previous[reportKey(incoming[j])]
      merged.push(known && !known.noUsage && Number(known.fetchedAt) > Number(incoming[j].fetchedAt) ? known : incoming[j])
    }
    reports = merged
    nowMs = Date.now()
    if (selectedIndex >= reports.length) selectedIndex = 0
    errorText = ""
  }

  Component.onCompleted: refresh()
  onOpenedChanged: if (opened) {
    nowMs = Date.now()
    refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  Process {
    id: usageProcess
    command: ["omp", "usage", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseUsage(text)
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
    function next(): string { root.selectProvider(root.selectedIndex + 1); return "ok" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // The stock Agents widget uses a glyph through BarIconButton. π is the
    // Oh My Pi mark here, avoiding a theme-dependent raster asset.
    text: "π"
    active: root.alarming
    tooltipText: root.provider ? "OMP Usage · " + root.providerName(root.provider.provider) : "OMP Usage"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.selectProvider(root.selectedIndex + 1)
      else root.toggle()
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
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.selectProvider(root.selectedIndex + dx)
        if (dy !== 0) panelFlick.contentY = Math.max(0, Math.min(panelFlick.contentHeight - panelFlick.height,
          panelFlick.contentY + dy * Style.space(56)))
      }
      onActivateRequested: root.refresh()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r" || text === "R") root.refresh()
        if (text === "h" || text === "H") root.selectProvider(root.selectedIndex - 1)
        if (text === "l" || text === "L") root.selectProvider(root.selectedIndex + 1)
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
            title: root.provider ? root.providerName(root.provider.provider) : "OMP Usage"
            meta: root.heroMeta(root.provider)
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Item {
                readonly property string iconSource: root.provider ? root.providerIcon(root.provider.provider) : ""
                width: Style.font.display
                height: Style.font.display
                Image {
                  anchors.fill: parent
                  visible: parent.iconSource !== ""
                  source: parent.iconSource
                  sourceSize.width: Style.font.display * 2
                  sourceSize.height: Style.font.display * 2
                  fillMode: Image.PreserveAspectFit
                }
                // Providers without a bundled logo get their initial instead.
                Text {
                  anchors.centerIn: parent
                  visible: parent.iconSource === ""
                  text: root.provider ? root.providerName(root.provider.provider).charAt(0) : "π"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                  font.bold: true
                }
              }
            }
          }

          Row {
            visible: root.reports.length > 1
            width: parent.width
            spacing: Style.spacing.md
            Repeater {
              model: root.reports
              Button {
                required property var modelData
                required property int index
                width: (parent.width - parent.spacing * (root.reports.length - 1)) / root.reports.length
                text: root.providerName(modelData.provider)
                selected: index === root.selectedIndex
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.selectProvider(index)
              }
            }
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          Column {
            visible: limitRepeater.count > 0
            width: parent.width
            spacing: Style.space(10)
            PanelSectionHeader {
              width: parent.width
              text: "LIMITS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            Repeater {
              id: limitRepeater
              model: root.provider && Array.isArray(root.provider.limits) ? root.provider.limits : []
              LimitRow {
                required property var modelData
                width: parent.width
                limit: modelData
              }
            }
          }

          Text {
            visible: text !== ""
            width: parent.width
            text: root.errorText !== "" ? ""
              : !root.provider ? "No accounts logged in to Oh My Pi. Run omp and use /login."
              : root.provider.noUsage ? "Logged in, but " + root.providerName(root.provider.provider)
                + " doesn't report usage to Oh My Pi."
              : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            visible: !!(root.provider && root.provider.resetCredits) && Number(root.provider.resetCredits.availableCount) > 0
            width: parent.width
            text: Number(root.provider && root.provider.resetCredits && root.provider.resetCredits.availableCount)
              + " saved reset" + (Number(root.provider && root.provider.resetCredits && root.provider.resetCredits.availableCount) === 1 ? "" : "s")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            visible: text !== ""
            width: parent.width
            text: root.staleText(root.provider)
            color: root.urgent
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
            text: "r refresh" + (root.reports.length > 1 ? " · h/l switch account" : "") + " · Esc close"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }
        }
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
