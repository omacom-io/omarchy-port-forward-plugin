import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "port-forward"
  ipcTarget: "port-forward"
  manageIpc: false

  readonly property real openIndicatorInlineOffset: bar && bar.vertical ? 0 : Style.spaceReal(1.5)

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color barForegroundColor: bar ? bar.barForeground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : Style.hoverFill
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : Style.selectedFill

  // Bar glyphs (Material Design Nerd Font, same family the other panels use).
  readonly property string iconGlyph: "󰛳"      // lan / network
  readonly property string glyphSwap: "󰓡"       // swap-horizontal
  readonly property string glyphEdit: "󰏫"       // pencil
  readonly property string glyphDelete: "󰆴"     // trash
  readonly property string glyphAdd: "󰐕"        // plus-circle
  readonly property string glyphPower: "󰐥"      // power
  readonly property string glyphKey: "󰌋"        // key — pending auth / trust host key

  // Keyboard cursor over the list. Index 0..forwards.length-1 are forward
  // rows; index === forwards.length is the "Add forward" row.
  property bool cursorActive: false
  property int rowIndex: 0
  readonly property int addRowIndex: svc.forwards.length

  // Inline add/edit form.
  property bool formMode: false
  property string editingId: ""
  property string draftLabel: ""
  property int draftLocalPort: 3000
  property string draftTarget: ""
  property string draftRemoteHost: "localhost"
  property int draftRemotePort: 3000
  property bool draftAutostart: false
  property string draftExtra: ""

  property string pendingDeleteId: ""

  function clampCursor() {
    var max = svc.forwards.length // add row is the last selectable index
    if (rowIndex < 0) rowIndex = 0
    if (rowIndex > max) rowIndex = max
  }

  function selectedForward() {
    if (rowIndex < 0 || rowIndex >= svc.forwards.length) return null
    return svc.forwards[rowIndex]
  }

  function moveCursor(dy) {
    cursorActive = true
    clampCursor()
    var max = svc.forwards.length
    rowIndex = Math.max(0, Math.min(max, rowIndex + dy))
    scrollCursorIntoView()
  }

  function activateCursor() {
    if (rowIndex === addRowIndex) { openAddForm(); return }
    var f = selectedForward()
    if (f) svc.toggle(f)
  }

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function scrollCursorIntoView() {
    if (!rowColumn) return
    if (rowIndex >= 0 && rowIndex < rowColumn.children.length) scrollItemIntoView(rowColumn.children[rowIndex])
    else if (rowIndex === addRowIndex && addRow) scrollItemIntoView(addRow)
  }

  function setRowCursor(index) {
    cursorActive = true
    rowIndex = index
  }

  // --- form helpers --------------------------------------------------------

  function openAddForm() {
    editingId = ""
    draftLabel = ""
    draftLocalPort = 3000
    draftTarget = ""
    draftRemoteHost = "localhost"
    draftRemotePort = 3000
    draftAutostart = false
    draftExtra = ""
    formMode = true
    Qt.callLater(function() { if (labelField) labelField.forceActiveFocus() })
  }

  function openEditForm(f) {
    if (!f) return
    editingId = String(f.id)
    draftLabel = f.label
    draftLocalPort = f.localPort
    draftTarget = f.sshTarget
    draftRemoteHost = f.remoteHost
    draftRemotePort = f.remotePort
    draftAutostart = f.autostart
    draftExtra = f.extraOptions
    formMode = true
    Qt.callLater(function() { if (labelField) labelField.forceActiveFocus() })
  }

  function closeForm() {
    formMode = false
    editingId = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function submitForm() {
    var def = {
      label: draftLabel,
      localPort: draftLocalPort,
      sshTarget: draftTarget,
      remoteHost: draftRemoteHost,
      remotePort: draftRemotePort,
      autostart: draftAutostart,
      extraOptions: draftExtra
    }
    if (String(draftTarget).trim() === "") { svc.flash("SSH host is required"); return }
    var ok
    if (editingId === "") ok = svc.addForward(def) !== null
    else ok = svc.updateForward(editingId, def)
    if (ok) closeForm()
  }

  function requestDelete(f) {
    if (!f) return
    pendingDeleteId = String(f.id)
    confirmDialog.message = "Delete \"" + svc.forwardTitle(f) + "\"?"
    confirmDialog.selectedIndex = 0
    confirmDialog.opened = true
    Qt.callLater(function() { confirmDialog.forceActiveFocus() })
  }

  function statusColor(status) {
    if (status === "active") return foreground
    if (status === "connecting") return Qt.lighter(dim, 1.2)
    if (status === "auth") return urgent
    if (status === "error") return urgent
    return dim
  }

  function statusGlyph(status) {
    if (status === "active") return "●"
    if (status === "connecting") return "◐"
    if (status === "auth") return "◉"
    if (status === "error") return "✕"
    return "○"
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    formMode = false
    pendingDeleteId = ""
    confirmDialog.opened = false
    if (panelFlick) panelFlick.contentY = 0
    clampCursor()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Service {
    id: svc
  }

  Connections {
    target: svc
    function onChanged() { root.clampCursor() }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { svc.refresh(); return "ok" }
    function list(): string { return JSON.stringify(svc.forwards) }
    function statuses(): string {
      var out = {}
      for (var i = 0; i < svc.forwards.length; i++) {
        var f = svc.forwards[i]
        out[f.id] = { label: svc.forwardTitle(f), localPort: f.localPort, status: svc.statusOf(f.id), authUrl: svc.authUrlOf(f.id) }
      }
      return JSON.stringify(out)
    }
    function on(ref: string): string {
      var f = svc.ipcForwardByRef(ref)
      if (!f) return "unknown"
      svc.start(f)
      return "ok"
    }
    function off(ref: string): string {
      var f = svc.ipcForwardByRef(ref)
      if (!f) return "unknown"
      svc.stop(f.id)
      return "ok"
    }
    function toggleForward(ref: string): string {
      var f = svc.ipcForwardByRef(ref)
      if (!f) return "unknown"
      svc.toggle(f)
      return "ok"
    }
  }

  // --- bar button ----------------------------------------------------------

  Item {
    id: button
    anchors.fill: parent
    implicitWidth: root.bar && root.bar.vertical ? root.bar.barSize : Style.space(27)
    implicitHeight: root.bar && root.bar.vertical ? Style.space(26) : (root.bar ? root.bar.barSize : Style.space(26))

    property var registeredBar: null

    function triggerPress(buttonCode) {
      if (buttonCode === Qt.MiddleButton) svc.refresh()
      else root.toggle()
    }

    function syncClickRegistration() {
      if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(button)
      registeredBar = root.bar
      if (registeredBar && registeredBar.registerClickTarget) registeredBar.registerClickTarget(button)
    }

    Component.onCompleted: syncClickRegistration()
    Component.onDestruction: if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(button)

    Connections {
      target: root
      function onBarChanged() { button.syncClickRegistration() }
    }

    Text {
      id: barGlyph
      anchors.centerIn: parent
      anchors.horizontalCenterOffset: root.openIndicatorInlineOffset
      text: root.iconGlyph
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon
      color: svc.authCount > 0 ? root.urgent
           : svc.activeCount > 0 ? root.barForegroundColor
           : Qt.darker(root.barForegroundColor, 1.55)
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: function(mouse) { button.triggerPress(mouse.button) }
    }
  }

  // --- popup ---------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.formMode || confirmDialog.opened

      onMoveRequested: function(dx, dy) {
        if (dy === 0) return
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onDeleteRequested: { var f = root.selectedForward(); if (f) root.requestDelete(f) }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "a" || t === "A") root.openAddForm()
        else if (t === "e" || t === "E") { var f = root.selectedForward(); if (f) root.openEditForm(f) }
        else if (t === "r" || t === "R") svc.refresh()
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

          // Hero -------------------------------------------------------------
          PanelHero {
            id: hero
            width: parent.width
            title: "Port forwarding"
            meta: svc.activeCount + " active · " + svc.forwards.length + " total"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: root.iconGlyph
                color: svc.activeCount > 0 ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          // Status / error / attention line -----------------------------------
          Text {
            readonly property string headerError: (svc.statusRevision, svc.currentErrorText())
            readonly property string headerAuth: (svc.statusRevision, svc.currentAuthText())
            visible: svc.notice !== "" || headerError !== "" || headerAuth !== ""
            width: parent.width
            text: svc.notice !== "" ? svc.notice : (headerError !== "" ? headerError : headerAuth)
            color: (svc.notice === "" && (headerError !== "" || headerAuth !== "")) ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ssh missing note ------------------------------------------------
          CursorSurface {
            visible: !svc.sshAvailable
            width: parent.width
            implicitHeight: sshMissing.implicitHeight + Style.spacing.rowPaddingX
            foreground: root.foreground

            Text {
              id: sshMissing
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(12)
              text: "The ssh client is not installed or not on PATH."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }
          }

          // ===== LIST MODE =================================================
          Column {
            visible: !root.formMode
            width: parent.width
            spacing: Style.space(10)

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "FORWARDS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              visible: svc.forwards.length === 0
              width: parent.width
              text: "No forwards yet. Add one below to tunnel a local port to a remote."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Column {
              id: rowColumn
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: svc.forwards
                ForwardRow {
                  required property var modelData
                  required property int index
                  width: rowColumn.width
                  forward: modelData
                  rowIdx: index
                }
              }
            }

            // Add row
            CursorSurface {
              id: addRow
              width: parent.width
              hasCursor: root.cursorActive && root.rowIndex === root.addRowIndex
              foreground: root.foreground
              fill: root.hoverFill
              implicitHeight: addInner.implicitHeight + Style.spacing.xl

              Row {
                id: addInner
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(8)
                spacing: Style.space(8)

                Text {
                  text: root.glyphAdd
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.icon
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  text: "Add forward"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root.setRowCursor(root.addRowIndex)
                onClicked: root.openAddForm()
              }
            }
          }

          // ===== FORM MODE =================================================
          Column {
            visible: root.formMode
            width: parent.width
            spacing: Style.space(12)

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: root.editingId === "" ? "NEW FORWARD" : "EDIT FORWARD"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            FormField {
              width: parent.width
              label: "Label (optional)"
              TextField {
                id: labelField
                width: parent.width
                foreground: root.foreground
                placeholderText: "e.g. Foundry web"
                text: root.draftLabel
                onTextChanged: root.draftLabel = text
                Keys.onEscapePressed: root.closeForm()
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(12)

              FormField {
                width: (parent.width - Style.space(12)) / 2
                label: "Local port"
                NumberField {
                  width: parent.width
                  from: 1
                  to: 65535
                  value: root.draftLocalPort
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onModified: function(v) { root.draftLocalPort = v }
                }
              }

              FormField {
                width: (parent.width - Style.space(12)) / 2
                label: "Remote port"
                NumberField {
                  width: parent.width
                  from: 1
                  to: 65535
                  value: root.draftRemotePort
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onModified: function(v) { root.draftRemotePort = v }
                }
              }
            }

            FormField {
              width: parent.width
              label: "SSH host (from ~/.ssh/config or user@host)"
              TextField {
                width: parent.width
                foreground: root.foreground
                placeholderText: "e.g. foundry"
                text: root.draftTarget
                onTextChanged: root.draftTarget = text
                Keys.onEscapePressed: root.closeForm()
              }
            }

            FormField {
              width: parent.width
              label: "Remote bind host"
              TextField {
                width: parent.width
                foreground: root.foreground
                placeholderText: "localhost"
                text: root.draftRemoteHost
                onTextChanged: root.draftRemoteHost = text
                Keys.onEscapePressed: root.closeForm()
              }
            }

            FormField {
              width: parent.width
              label: "Extra ssh options (optional)"
              TextField {
                width: parent.width
                foreground: root.foreground
                placeholderText: "e.g. -J bastion"
                text: root.draftExtra
                onTextChanged: root.draftExtra = text
                Keys.onEscapePressed: root.closeForm()
              }
            }

            Toggle {
              width: parent.width
              label: "Start on shell launch"
              description: "Reconnect this forward automatically when the shell starts."
              checked: root.draftAutostart
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.draftAutostart = !root.draftAutostart
            }

            Row {
              width: parent.width
              layoutDirection: Qt.RightToLeft
              spacing: Style.space(10)

              Button {
                text: root.editingId === "" ? "Add" : "Save"
                bordered: true
                focusable: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.submitForm()
              }

              Button {
                text: "Cancel"
                bordered: true
                focusable: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.closeForm()
              }
            }
          }
        }
      }
    }

    // Confirm delete overlay (covers the whole card).
    ConfirmDialog {
      id: confirmDialog
      anchors.fill: parent
      confirmText: "Delete"
      foreground: root.foreground
      fontFamily: root.fontFamily
      onConfirmed: {
        if (root.pendingDeleteId !== "") svc.removeForward(root.pendingDeleteId)
        root.pendingDeleteId = ""
        opened = false
        Qt.callLater(function() { keyCatcher.forceActiveFocus() })
      }
      onCanceled: {
        root.pendingDeleteId = ""
        opened = false
        Qt.callLater(function() { keyCatcher.forceActiveFocus() })
      }
      Keys.onPressed: function(event) { if (handleKey(event)) event.accepted = true }
      focus: opened
    }
  }

  // --- components ----------------------------------------------------------

  // Label-over-control form field wrapper.
  component FormField: Column {
    property string label: ""
    default property alias content: holder.children
    spacing: Style.space(4)

    Text {
      text: parent.label
      visible: text !== ""
      color: Qt.darker(root.foreground, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Item {
      id: holder
      width: parent.width
      implicitHeight: childrenRect.height
    }
  }

  component ForwardRow: CursorSurface {
    id: fwdRow
    property var forward: null
    property int rowIdx: 0
    readonly property string fid: forward ? String(forward.id) : ""
    readonly property string status: (svc.statusRevision, forward ? svc.statusOf(fid) : "inactive")
    readonly property string hostKeyIssue: (svc.statusRevision, forward ? svc.hostKeyIssueOf(fid) : "")
    readonly property bool activeState: status === "active" || status === "connecting" || status === "auth"
    readonly property bool needsAuth: status === "auth"
    readonly property bool canTrustHostKey: status === "error" && hostKeyIssue === "new"

    hasCursor: root.cursorActive && !root.formMode && root.rowIndex === rowIdx
    current: activeState
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill

    implicitHeight: Math.max(rowContent.implicitHeight, Style.space(40)) + Style.spacing.rowPaddingX

    // Hover + click-to-toggle on the row body (declared first so the action
    // buttons below sit on top and receive their own clicks).
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.setRowCursor(fwdRow.rowIdx)
      onClicked: {
        if (!fwdRow.forward) return
        // A row waiting on approval opens the approval page; the power
        // button remains the way to give up and turn it off.
        if (fwdRow.needsAuth) svc.openAuth(fwdRow.fid)
        else svc.toggle(fwdRow.forward)
      }
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      Text {
        text: root.statusGlyph(fwdRow.status)
        color: root.statusColor(fwdRow.status)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        Layout.alignment: Qt.AlignVCenter
        // Gentle pulse while a tunnel is establishing or waiting on the user
        // to approve. Base opacity is bound to status so it restores to full
        // once the animation stops.
        opacity: (fwdRow.status === "connecting" || fwdRow.needsAuth) ? 0.999 : 1.0

        SequentialAnimation on opacity {
          running: fwdRow.status === "connecting" || fwdRow.needsAuth
          loops: Animation.Infinite
          NumberAnimation { to: 0.3; duration: 650; easing.type: Easing.InOutQuad }
          NumberAnimation { to: 1.0; duration: 650; easing.type: Easing.InOutQuad }
        }
      }

      ColumnLayout {
        id: rowContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: svc.forwardTitle(fwdRow.forward)
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: fwdRow.activeState
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: fwdRow.status === "error" ? svc.errorOf(fwdRow.fid)
              : fwdRow.needsAuth ? "Approval required — click to open the authentication page"
              : svc.forwardSubtitle(fwdRow.forward)
          color: (fwdRow.status === "error" || fwdRow.needsAuth) ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        visible: fwdRow.needsAuth || fwdRow.canTrustHostKey
        iconText: root.glyphKey
        tooltipText: fwdRow.needsAuth ? "Open authentication page" : "Trust host key & retry"
        foreground: root.foreground
        hoverColor: root.urgent
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: {
          if (fwdRow.needsAuth) svc.openAuth(fwdRow.fid)
          else if (fwdRow.forward) svc.trustAndRetry(fwdRow.forward)
        }
      }

      PanelActionButton {
        iconText: fwdRow.activeState ? root.glyphPower : root.glyphSwap
        tooltipText: fwdRow.activeState ? "Turn off" : "Turn on"
        foreground: root.foreground
        hoverColor: fwdRow.activeState ? root.urgent : root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: if (fwdRow.forward) svc.toggle(fwdRow.forward)
      }

      PanelActionButton {
        iconText: root.glyphEdit
        tooltipText: "Edit"
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.openEditForm(fwdRow.forward)
      }

      PanelActionButton {
        iconText: root.glyphDelete
        tooltipText: "Delete"
        foreground: root.foreground
        hoverColor: root.urgent
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.requestDelete(fwdRow.forward)
      }
    }
  }
}
