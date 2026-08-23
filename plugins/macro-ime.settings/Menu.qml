import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import qs.Commons
import qs.Ui

// Macro IME Settings — Native Chinese Input Method Control Panel
//
// Dual-engine Chinese IME for Omarchy desktop.
// Triggered via: `omarchy-shell shell toggle macro-ime.settings '{}'`

Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false

  readonly property string configBin: Quickshell.env("HOME") + "/.local/share/macro-ime/bin/macro-ime-config"
  readonly property string uiFontFamily: "Maple Mono NF CN, " + (Style.font && Style.font.family ? Style.font.family : "monospace")

  // ---- State model from macro-ime-config get-all --json
  property bool imActive: false
  property bool vertical: false
  property string correction: "None"
  property var fuzzy: ({})
  property bool contextInter: false
  property int userModelWeight: 20
  property bool busy: false
  property bool showResetConfirm: false
  property bool showFuzzyDetails: false
  property string notice: ""

  readonly property var weightStages: [
    { weight: 0,   label: "0 纯净",   desc: "原生纯净 · 不提升个人习惯词频" },
    { weight: 10,  label: "10 轻度",  desc: "轻度偏好 · 循序渐进自适应" },
    { weight: 20,  label: "20 均衡",  desc: "均衡推荐 · 最佳日常打字平衡" },
    { weight: 50,  label: "50 积极",  desc: "积极偏好 · 常用词迅速置顶" },
    { weight: 100, label: "100 极速", desc: "极速自学 · 个人词频最高优先级" }
  ]

  readonly property var fuzzyCategories: [
    {
      id: "shuang",
      name: "平翘舌音",
      desc: "z ⇄ zh · c ⇄ ch · s ⇄ sh",
      pairs: [
        { key: "z_zh", label: "z ⇄ zh" },
        { key: "c_ch", label: "c ⇄ ch" },
        { key: "s_sh", label: "s ⇄ sh" }
      ]
    },
    {
      id: "bi",
      name: "前后鼻音",
      desc: "an/ang · en/eng · in/ing · ian/iang · uan/uang",
      pairs: [
        { key: "an_ang",   label: "an ⇄ ang" },
        { key: "en_eng",   label: "en ⇄ eng" },
        { key: "in_ing",   label: "in ⇄ ing" },
        { key: "ian_iang", label: "ian ⇄ iang" },
        { key: "uan_uang", label: "uan ⇄ uang" }
      ]
    },
    {
      id: "sheng_yun",
      name: "声母与韵母",
      desc: "l ⇄ n · f ⇄ h · l ⇄ r · v ⇄ u · u ⇄ ou",
      pairs: [
        { key: "l_n",  label: "l ⇄ n" },
        { key: "f_h",  label: "f ⇄ h" },
        { key: "l_r",  label: "l ⇄ r" },
        { key: "v_u",  label: "v ⇄ u" },
        { key: "u_ou", label: "u ⇄ ou" }
      ]
    }
  ]

  readonly property int activeFuzzyCount: {
    var c = 0
    for (var i = 0; i < fuzzyCategories.length; i++) {
      var pairs = fuzzyCategories[i].pairs
      for (var j = 0; j < pairs.length; j++) {
        if (fuzzy[pairs[j].key] === true) c++
      }
    }
    return c
  }

  function getGroupActiveCount(cat) {
    var c = 0
    for (var i = 0; i < cat.pairs.length; i++) {
      if (fuzzy[cat.pairs[i].key] === true) c++
    }
    return c
  }

  function toggleGroup(cat) {
    if (busy) return
    var cur = getGroupActiveCount(cat)
    var target = cur < cat.pairs.length ? "true" : "false"
    runActionArgs(["fuzzy-group-set", cat.id, target])
  }

  function currentWeightDesc() {
    for (var i = 0; i < weightStages.length; i++) {
      if (weightStages[i].weight === userModelWeight) {
        return weightStages[i].desc
      }
    }
    return userModelWeight + " / 100 自定义权重"
  }

  function open(payloadJson) {
    opened = true
    showResetConfirm = false
    showFuzzyDetails = false
    notice = ""
    refreshState()
  }

  function close() {
    opened = false
    showResetConfirm = false
    showFuzzyDetails = false
  }

  function ping() { return "ok" }

  function refreshState() {
    stateProc.running = true
  }

  function apply(keyPath, value) {
    if (busy) return
    busy = true
    setArgs = [configBin, "set", keyPath, String(value)]
    setProc.command = setArgs
    setProc.running = true
  }

  function runAction(name) {
    if (busy) return
    busy = true
    setArgs = [configBin, "action", name]
    setProc.command = setArgs
    setProc.running = true
  }

  function runActionArgs(args) {
    if (busy) return
    busy = true
    setArgs = [configBin, "action"].concat(args)
    setProc.command = setArgs
    setProc.running = true
  }

  onNoticeChanged: {
    if (notice !== "") {
      noticeTimer.restart()
    }
  }

  Timer {
    id: noticeTimer
    interval: 2400
    onTriggered: root.notice = ""
  }

  // ---------------------------------------------------------------- Window
  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "macro-ime-settings"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    // Dimmed Scrim
    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.45)
      opacity: root.opened ? 1.0 : 0.0
      Behavior on opacity { NumberAnimation { duration: 150 } }

      MouseArea {
        anchors.fill: parent
        onClicked: root.close()
      }
    }

    // Centered Compact Modal Card
    Rectangle {
      id: card
      focus: root.opened
      Keys.onEscapePressed: root.close()
      anchors.centerIn: parent
      width: Math.min(480, panel.width - Style.space(32))
      height: Math.min(600, panel.height - Style.space(32))
      radius: Style.cornerRadius > 0 ? Style.cornerRadius : 12
      color: Color.popups.background
      border.width: 1
      border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.24)
      clip: true

      Column {
        anchors.fill: parent

        // ========================================================= Header
        Item {
          id: cardHeader
          width: parent.width
          height: Style.space(48)

          Row {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(16)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Text {
              text: "Macro IME"
              color: Color.foreground
              font.family: root.uiFontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          // Dynamic Notice Toast
          Rectangle {
            anchors.centerIn: parent
            height: Style.space(24)
            width: noticeText.implicitWidth + Style.space(16)
            visible: root.notice !== ""
            radius: height / 2
            color: root.showResetConfirm
              ? Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.18)
              : Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18)
            border.width: 1
            border.color: root.showResetConfirm ? Color.urgent : Color.accent

            Text {
              id: noticeText
              anchors.centerIn: parent
              text: root.notice
              color: root.showResetConfirm ? Color.urgent : Color.accent
              font.family: root.uiFontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          // Close Button
          Rectangle {
            anchors.right: parent.right
            anchors.rightMargin: Style.space(14)
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(26)
            height: Style.space(26)
            radius: width / 2
            color: closeMouse.containsMouse ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.12) : "transparent"

            Text {
              anchors.centerIn: parent
              text: "✕"
              color: Color.foreground
              opacity: closeMouse.containsMouse ? 1.0 : 0.6
              font.family: root.uiFontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }

            MouseArea {
              id: closeMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.close()
            }
          }
        }

        // Header Divider
        PanelSeparator {
          width: parent.width
        }

        // ========================================================= Scrollable Body
        Flickable {
          id: scrollArea
          width: parent.width
          height: parent.height - cardHeader.height - 1
          contentWidth: width
          contentHeight: contentCol.implicitHeight + Style.space(24)
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          Column {
            id: contentCol
            width: parent.width - Style.space(32)
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: Style.space(12)
            spacing: Style.space(12)

            // ------------------------------------------------- Section 1: 排版与外观
            PanelSectionHeader {
              text: "排版与外观"
            }

            Rectangle {
              width: parent.width
              height: Style.space(44)
              radius: Style.space(6)
              color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.03)
              border.width: 1
              border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.08)

              Row {
                anchors.fill: parent
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(8)

                Text {
                  text: "候选词排列方向"
                  color: Color.foreground
                  font.family: root.uiFontFamily
                  font.pixelSize: Style.font.body
                  anchors.verticalCenter: parent.verticalCenter
                }

                Item {
                  width: parent.width - 120 - 170
                  height: 1
                }

                Row {
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(4)

                  Rectangle {
                    width: Style.space(80)
                    height: Style.space(28)
                    radius: Style.space(4)
                    color: !root.vertical
                      ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.22)
                      : (hMouse.containsMouse ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.06) : "transparent")
                    border.width: 1
                    border.color: !root.vertical ? Color.accent : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.12)

                    Text {
                      anchors.centerIn: parent
                      text: "横向排布"
                      color: !root.vertical ? Color.accent : Color.foreground
                      font.family: root.uiFontFamily
                      font.bold: !root.vertical
                      font.pixelSize: Style.font.caption
                    }
                    MouseArea {
                      id: hMouse
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: if (!root.busy && root.vertical) root.apply("candidates.vertical", "false")
                    }
                  }

                  Rectangle {
                    width: Style.space(80)
                    height: Style.space(28)
                    radius: Style.space(4)
                    color: root.vertical
                      ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.22)
                      : (vMouse.containsMouse ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.06) : "transparent")
                    border.width: 1
                    border.color: root.vertical ? Color.accent : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.12)

                    Text {
                      anchors.centerIn: parent
                      text: "纵向列表"
                      color: root.vertical ? Color.accent : Color.foreground
                      font.family: root.uiFontFamily
                      font.bold: root.vertical
                      font.pixelSize: Style.font.caption
                    }
                    MouseArea {
                      id: vMouse
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: if (!root.busy && !root.vertical) root.apply("candidates.vertical", "true")
                    }
                  }
                }
              }
            }

            // ------------------------------------------------- Section 2: 智能与习惯
            PanelSeparator {}

            PanelSectionHeader {
              text: "智能与习惯"
            }

            Toggle {
              width: parent.width
              label: "键盘智能纠错 (QWERTY)"
              description: "自动纠正误触相邻键的拼写错误（如 ihao 自动识别为 nihao）"
              checked: root.correction === "QWERTY"
              enabled: !root.busy
              onClicked: root.apply("correction", root.correction === "QWERTY" ? "None" : "QWERTY")
            }

            Toggle {
              width: parent.width
              label: "跨句上下文联想预测"
              description: "上一句上屏词参与下一句首词预测，提升长句连续输入连贯性"
              checked: root.contextInter
              enabled: !root.busy
              onClicked: root.apply("context.inter", !root.contextInter ? "true" : "false")
            }

            Rectangle {
              width: parent.width
              height: Style.space(78)
              radius: Style.space(6)
              color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.03)
              border.width: 1
              border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.08)

              Column {
                anchors.fill: parent
                anchors.margins: Style.space(10)
                spacing: Style.space(6)

                Item {
                  width: parent.width
                  height: Style.space(18)

                  Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: "自适应学习权重"
                    color: Color.foreground
                    font.family: root.uiFontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.currentWeightDesc()
                    color: Color.accent
                    font.family: root.uiFontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Row {
                  width: parent.width
                  spacing: Style.space(4)

                  Repeater {
                    model: root.weightStages
                    delegate: Rectangle {
                      required property var modelData
                      readonly property bool active: root.userModelWeight === modelData.weight
                      width: (parent.width - Style.space(4) * (root.weightStages.length - 1)) / root.weightStages.length
                      height: Style.space(28)
                      radius: Style.space(4)
                      color: active
                        ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.22)
                        : (wmouse.containsMouse ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.06) : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.02))
                      border.width: 1
                      border.color: active ? Color.accent : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.12)

                      Text {
                        anchors.centerIn: parent
                        text: modelData.label
                        color: parent.active ? Color.accent : Color.foreground
                        font.family: root.uiFontFamily
                        font.bold: parent.active
                        font.pixelSize: Style.font.caption
                      }
                      MouseArea {
                        id: wmouse
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: if (!root.busy) root.apply("usermodel.weight", String(modelData.weight))
                      }
                    }
                  }
                }
              }
            }

            // ------------------------------------------------- Section 3: 模糊音匹配
            PanelSeparator {}

            Item {
              width: parent.width
              height: Style.space(26)

              Row {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                PanelSectionHeader {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "模糊音匹配"
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.activeFuzzyCount === 0 ? "(未开启)" : "(已开启 " + root.activeFuzzyCount + " 项)"
                  color: root.activeFuzzyCount > 0 ? Color.accent : Qt.darker(Color.foreground, 1.5)
                  font.family: root.uiFontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)

                Button {
                  text: "全部关闭"
                  bordered: true
                  fontSize: Style.font.caption
                  enabled: !root.busy
                  onClicked: root.runAction("fuzzy-clear")
                }
                Button {
                  text: "南方常用"
                  bordered: true
                  fontSize: Style.font.caption
                  enabled: !root.busy
                  onClicked: root.runAction("fuzzy-preset-common")
                }
                Button {
                  text: root.showFuzzyDetails ? "收起明细 ▴" : "详细微调 ▾"
                  bordered: true
                  fontSize: Style.font.caption
                  onClicked: root.showFuzzyDetails = !root.showFuzzyDetails
                }
              }
            }

            // Group Toggle Rows (Clean 3-row layout)
            Column {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.fuzzyCategories
                delegate: Rectangle {
                  id: fcatRow
                  required property var modelData
                  readonly property int activeCount: root.getGroupActiveCount(modelData)
                  readonly property bool allOn: activeCount === modelData.pairs.length
                  readonly property bool partialOn: activeCount > 0 && activeCount < modelData.pairs.length

                  width: parent.width
                  height: Style.space(48)
                  radius: Style.space(6)
                  color: fcatMouse.containsMouse
                    ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.05)
                    : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.02)
                  border.width: 1
                  border.color: (allOn || partialOn)
                    ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.3)
                    : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.08)

                  Row {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(12)
                    anchors.rightMargin: Style.space(12)

                    Column {
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: 2

                      Row {
                        spacing: Style.space(6)
                        Text {
                          text: fcatRow.modelData.name
                          color: (fcatRow.allOn || fcatRow.partialOn) ? Color.accent : Color.foreground
                          font.family: root.uiFontFamily
                          font.bold: true
                          font.pixelSize: Style.font.bodySmall
                        }
                        Text {
                          visible: fcatRow.partialOn
                          text: "(" + fcatRow.activeCount + "/" + fcatRow.modelData.pairs.length + ")"
                          color: Color.accent
                          font.family: root.uiFontFamily
                          font.pixelSize: Style.font.caption
                          anchors.verticalCenter: parent.verticalCenter
                        }
                      }

                      Text {
                        text: fcatRow.modelData.desc
                        color: Qt.darker(Color.foreground, 1.4)
                        font.family: root.uiFontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }

                    Item {
                      width: 1
                      height: 1
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    ToggleSwitch {
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      checked: fcatRow.allOn || fcatRow.partialOn
                      enabled: !root.busy
                      onToggled: root.toggleGroup(fcatRow.modelData)
                    }
                  }

                  MouseArea {
                    id: fcatMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleGroup(fcatRow.modelData)
                  }
                }
              }
            }

            // Detailed Micro-Chips (Collapsible)
            Rectangle {
              width: parent.width
              height: root.showFuzzyDetails ? fdetCol.implicitHeight + Style.space(16) : 0
              visible: height > 0
              radius: Style.space(6)
              color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.02)
              border.width: 1
              border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.08)
              clip: true

              Behavior on height { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

              Column {
                id: fdetCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Style.space(10)
                spacing: Style.space(10)

                Repeater {
                  model: root.fuzzyCategories
                  delegate: Column {
                    required property var modelData
                    width: parent.width
                    spacing: Style.space(4)

                    Text {
                      text: modelData.name + " 单项微调"
                      color: Qt.darker(Color.foreground, 1.5)
                      font.family: root.uiFontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }

                    Flow {
                      width: parent.width
                      spacing: Style.space(6)

                      Repeater {
                        model: modelData.pairs
                        delegate: Rectangle {
                          id: fchip
                          required property var modelData
                          readonly property bool on: root.fuzzy[modelData.key] === true
                          width: Style.space(80)
                          height: Style.space(24)
                          radius: Style.space(4)
                          color: on
                            ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.2)
                            : (cm.containsMouse ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.06) : "transparent")
                          border.width: 1
                          border.color: on ? Color.accent : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.12)

                          Text {
                            anchors.centerIn: parent
                            text: modelData.label
                            color: fchip.on ? Color.accent : Color.foreground
                            font.family: root.uiFontFamily
                            font.bold: fchip.on
                            font.pixelSize: Style.font.caption
                          }

                          MouseArea {
                            id: cm
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: if (!root.busy) root.apply("fuzzy." + modelData.key, !fchip.on ? "true" : "false")
                          }
                        }
                      }
                    }
                  }
                }
              }
            }

            // ------------------------------------------------- Section 4: 维护与操作
            PanelSeparator {}

            Row {
              width: parent.width
              spacing: Style.space(10)

              Button {
                width: (parent.width - Style.space(10)) / 2
                text: root.busy ? "处理中…" : "重新应用主题"
                bordered: true
                enabled: !root.busy
                onClicked: root.runAction("theme-regenerate")
              }

              Button {
                width: (parent.width - Style.space(10)) / 2
                text: "清空自学词库"
                bordered: true
                enabled: !root.busy
                accent: Color.urgent
                foreground: Color.urgent
                onClicked: root.showResetConfirm = true
              }
            }

            // Reset Confirm Drawer
            Rectangle {
              width: parent.width
              height: root.showResetConfirm ? rconfCol.implicitHeight + Style.space(16) : 0
              visible: height > 0
              radius: Style.space(6)
              color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.12)
              border.width: 1
              border.color: Color.urgent
              clip: true

              Behavior on height { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

              Column {
                id: rconfCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Style.space(8)
                spacing: Style.space(8)

                Text {
                  width: parent.width
                  text: "⚠ 确认重置？将清空所有自学习词汇与个性化词频记录，且不可撤销。"
                  color: Color.urgent
                  font.family: root.uiFontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }

                Row {
                  anchors.right: parent.right
                  spacing: Style.space(8)

                  Button {
                    text: "取消"
                    bordered: true
                    fontSize: Style.font.caption
                    onClicked: root.showResetConfirm = false
                  }

                  Button {
                    text: "确认立即清空"
                    bordered: true
                    accent: Color.urgent
                    foreground: Color.urgent
                    fontSize: Style.font.caption
                    onClicked: {
                      root.showResetConfirm = false
                      root.runAction("userdict-reset")
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  // ---------------------------------------------------------------- io
  property var setArgs: []

  Process {
    id: stateProc
    command: [root.configBin, "get-all", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          const s = JSON.parse(text)
          root.imActive = s.imActive === true
          root.vertical = s.vertical === true
          root.correction = String(s.correction || "None")
          root.fuzzy = s.fuzzy || {}
          root.contextInter = s.contextInter === true
          root.userModelWeight = Number(s.userModelWeight ?? 20)
        } catch (e) {
          root.notice = "读取配置失败：" + e
        }
      }
    }
  }

  Process {
    id: setProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      if (setArgs.length >= 2 && setArgs[1] === "action") {
        if (code === 0) {
          switch (setArgs[2]) {
            case "userdict-reset":
              root.notice = "自学词库与词频记录已重置"
              break
            case "theme-regenerate":
              root.notice = "主题已重新渲染"
              break
            case "fuzzy-clear":
              root.notice = "已关闭所有模糊音"
              break
            case "fuzzy-preset-common":
              root.notice = "已应用南方常用方案"
              break
            case "fuzzy-group-set":
              root.notice = "已更新模糊音方案"
              break
            default:
              root.notice = "设置已生效"
          }
        } else {
          root.notice = "操作失败 (错误码 " + code + ")"
        }
      } else {
        root.notice = code === 0 ? "配置已实时生效" : "写入配置失败 (错误码 " + code + ")"
      }
      root.busy = false
      root.refreshState()
    }
  }
}
