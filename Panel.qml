import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "mirceone.omp-usage"
  ipcTarget: "mirceone.omp-usage"
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
      if (Number(provider.limits[i].amount && provider.limits[i].amount.usedFraction) >= 0.9) return true
    return false
  }

  visible: reports.length > 0
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function providerName(id) {
    if (id === "openai-codex") return "Codex"
    if (id === "anthropic") return "Claude"
    return String(id || "Unknown provider")
  }

  function providerIcon(id) {
    if (id === "openai-codex") return Qt.resolvedUrl("assets/codex.svg")
    if (id === "anthropic") return Qt.resolvedUrl("assets/claude.svg")
    return ""
  }

  function accessType(report) {
    var metadata = report && report.metadata ? report.metadata : {}
    if (metadata.planType || String(metadata.endpoint || "").indexOf("/oauth/") >= 0) return "Subscription"
    return "API"
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
    var resetAt = Number(limit && limit.window && limit.window.resetsAt)
    return resetAt > 0 ? "Resets in " + formatDuration(resetAt - nowMs) : ""
  }

  function limitTitle(limit) {
    var title = String(limit && (limit.label || limit.window && limit.window.label) || "Usage")
    var scope = limit && limit.scope ? limit.scope : null
    if (scope && scope.modelId) title += " · " + scope.modelId
    return title
  }

  function parseUsage(text) {
    try {
      var parsed = JSON.parse(String(text || ""))
      reports = Array.isArray(parsed.reports) ? parsed.reports : []
      if (selectedIndex >= reports.length) selectedIndex = 0
      errorText = ""
    } catch (error) {
      reports = []
      errorText = "Could not read OMP usage data"
      console.warn("omp-usage", error)
    }
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
            meta: root.provider ? "Oh My Pi · " + root.accessType(root.provider) : "Oh My Pi"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Image {
                source: root.provider ? root.providerIcon(root.provider.provider) : ""
                sourceSize.width: Style.font.display * 2
                sourceSize.height: Style.font.display * 2
                width: Style.font.display
                height: Style.font.display
                fillMode: Image.PreserveAspectFit
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
            width: parent.width
            spacing: Style.space(10)
            PanelSectionHeader {
              width: parent.width
              text: "LIMITS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            Repeater {
              model: root.provider && Array.isArray(root.provider.limits) ? root.provider.limits : []
              LimitRow {
                required property var modelData
                width: parent.width
                limit: modelData
              }
            }
          }

          Text {
            visible: root.provider && root.provider.resetCredits && Number(root.provider.resetCredits.availableCount) > 0
            width: parent.width
            text: Number(root.provider && root.provider.resetCredits && root.provider.resetCredits.availableCount)
              + " saved reset" + (Number(root.provider && root.provider.resetCredits && root.provider.resetCredits.availableCount) === 1 ? "" : "s")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
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
            text: "r refresh · h/l switch subscription · Esc close"
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
    readonly property real fraction: Math.max(0, Math.min(1, Number(limit && limit.amount && limit.amount.usedFraction || 0)))
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
        text: Math.round(limitRow.fraction * 100) + "%"
        color: limitRow.alarming ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    Rectangle {
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
      width: parent.width
      text: root.resetText(limitRow.limit)
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
