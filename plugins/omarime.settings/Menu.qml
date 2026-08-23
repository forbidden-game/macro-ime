import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import qs.Commons
import qs.Ui

// omarime settings — compact native panel for the Chinese IME.
//
// Summoned with `omarchy-shell shell toggle omarime.settings '{}'`
// (the indicator widget's right-click does exactly that).
//
// Every control goes through ~/.local/share/omarime/bin/omarime-config.
// Persistent settings use Controller1.SetConfig so fcitx5 updates memory and
// disk atomically; a safe stop → edit → start path is fallback only.

Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false

  readonly property string configBin: Quickshell.env("HOME") + "/.local/share/omarime/bin/omarime-config"

  // ---- state model, populated by omarime-config get-all --json
  property bool imActive: false
  property bool vertical: false
  property string correction: "None"
  property var fuzzy: ({})
  property bool contextInter: false
  property int userModelWeight: 20
  property bool busy: false
  property bool confirmReset: false
  property string notice: ""

  readonly property var fuzzyCategories: [
    {
      name: "平翘舌音",
      pairs: [
        { key: "z_zh", label: "z ↔ zh" },
        { key: "c_ch", label: "c ↔ ch" },
        { key: "s_sh", label: "s ↔ sh" }
      ]
    },
    {
      name: "前后鼻音",
      pairs: [
        { key: "an_ang",   label: "an ↔ ang" },
        { key: "en_eng",   label: "en ↔ eng" },
        { key: "in_ing",   label: "in ↔ ing" },
        { key: "ian_iang", label: "ian ↔ iang" },
        { key: "uan_uang", label: "uan ↔ uang" }
      ]
    },
    {
      name: "声/韵母混淆",
      pairs: [
        { key: "l_n",  label: "l ↔ n" },
        { key: "f_h",  label: "f ↔ h" },
        { key: "l_r",  label: "l ↔ r" },
        { key: "v_u",  label: "v ↔ u" },
        { key: "u_ou", label: "u ↔ ou" }
      ]
    }
  ]

  function open(payloadJson) {
    opened = true
    notice = ""
    refreshState()
  }

  function close() {
    opened = false
    confirmReset = false
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

  // ---------------------------------------------------------------- window
  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarime-settings"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    // scrim
    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    Rectangle {
      id: card
      focus: root.opened
      Keys.onEscapePressed: root.close()
      anchors.centerIn: parent
      width: Math.min(540, panel.width - Style.space(40))
      height: Math.min(scrollContent.implicitHeight + Style.space(48), panel.height - Style.space(40))
      radius: Style.cornerRadius
      color: Color.popups.background
      border.width: Math.max(1, Style.space(2))
      border.color: Color.popups.border

      Flickable {
        id: flick
        anchors.fill: parent
        anchors.margins: Style.space(20)
        contentWidth: width
        contentHeight: scrollContent.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: scrollContent
          width: parent.width
          spacing: Style.spacing.md

          // Header
          Item {
            width: parent.width
            height: titleText.implicitHeight

            Row {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.sm

              Text {
                id: titleText
                text: "omarime · 中文输入设置"
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.title
                font.bold: true
              }
            }

            Text {
              text: "✕"
              color: Color.foreground
              opacity: 0.6
              font.pixelSize: Style.font.subtitle
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter

              MouseArea {
                anchors.fill: parent
                anchors.margins: -Style.space(8)
                cursorShape: Qt.PointingHandCursor
                onClicked: root.close()
              }
            }
          }

          // ------------------------------------------------ 1. 界面与排版
          PanelSeparator { foreground: Color.foreground }

          PanelSectionHeader {
            text: "界面与排版"
            foreground: Color.foreground
          }

          Row {
            width: parent.width
            spacing: Style.spacing.md

            Column {
              width: parent.width - dirButtons.width - parent.spacing
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.xxs

              Text {
                text: "候选词排列"
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
              }

              Text {
                text: "候选词窗口横向或纵向列表布局"
                color: Qt.darker(Color.foreground, 1.5)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            Row {
              id: dirButtons
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.xs

              Button {
                text: "横排 (默认)"
                selected: !root.vertical
                bordered: true
                focusable: true
                enabled: !root.busy
                onClicked: root.apply("candidates.vertical", "false")
              }
              Button {
                text: "竖排"
                selected: root.vertical
                bordered: true
                focusable: true
                enabled: !root.busy
                onClicked: root.apply("candidates.vertical", "true")
              }
            }
          }

          // ------------------------------------------------ 2. 智能输入与习惯
          PanelSeparator { foreground: Color.foreground }

          PanelSectionHeader {
            text: "智能输入与习惯"
            foreground: Color.foreground
          }

          // User habit adaptation weight
          Column {
            width: parent.width
            spacing: Style.spacing.xs

            Text {
              text: "个人习惯记忆 (自适应学习)"
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }

            Text {
              text: "根据打字历史动态提升个人常用词优先级（只提权不降权）"
              color: Qt.darker(Color.foreground, 1.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Row {
              spacing: Style.spacing.xs

              Button {
                text: "关闭"
                selected: root.userModelWeight === 0
                bordered: true
                focusable: true
                enabled: !root.busy
                onClicked: root.apply("usermodel.weight", "0")
              }
              Button {
                text: "轻度"
                selected: root.userModelWeight === 10
                bordered: true
                focusable: true
                enabled: !root.busy
                onClicked: root.apply("usermodel.weight", "10")
              }
              Button {
                text: "推荐"
                selected: root.userModelWeight === 20
                bordered: true
                focusable: true
                enabled: !root.busy
                onClicked: root.apply("usermodel.weight", "20")
              }
              Button {
                text: "较强"
                selected: root.userModelWeight === 50
                bordered: true
                focusable: true
                enabled: !root.busy
                onClicked: root.apply("usermodel.weight", "50")
              }
              Button {
                text: "极速"
                selected: root.userModelWeight === 100
                bordered: true
                focusable: true
                enabled: !root.busy
                onClicked: root.apply("usermodel.weight", "100")
              }
            }
          }

          // Pinyin correction
          Column {
            width: parent.width
            spacing: Style.spacing.xs

            Text {
              text: "键盘邻键容错"
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }

            Text {
              text: "自动纠正误触相邻键的拼音拼写错误"
              color: Qt.darker(Color.foreground, 1.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Row {
              spacing: Style.spacing.xs

              Button {
                text: "关闭"
                selected: root.correction === "None"
                bordered: true
                focusable: true
                enabled: !root.busy
                onClicked: root.apply("correction", "None")
              }
              Button {
                text: "QWERTY 邻键纠错"
                selected: root.correction === "QWERTY"
                bordered: true
                focusable: true
                enabled: !root.busy
                onClicked: root.apply("correction", "QWERTY")
              }
            }
          }

          // Cross-sentence context
          Toggle {
            width: parent.width
            label: "跨句连续上下文联想"
            description: "上一句上屏词参与下一句首词预测 · 关闭后相同拼音首选词更稳定"
            checked: root.contextInter
            enabled: !root.busy
            onClicked: root.apply("context.inter", !root.contextInter ? "true" : "false")
          }

          // ------------------------------------------------ 3. 模糊音匹配
          PanelSeparator { foreground: Color.foreground }

          Item {
            width: parent.width
            height: Math.max(fuzzyHeaderCol.implicitHeight, fuzzyActionsRow.implicitHeight)

            Column {
              id: fuzzyHeaderCol
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.xxs

              PanelSectionHeader {
                text: "模糊音匹配"
                foreground: Color.foreground
              }

              Text {
                text: "全部关闭时拼音匹配最精准"
                color: Qt.darker(Color.foreground, 1.5)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            Row {
              id: fuzzyActionsRow
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.xs

              Button {
                text: "全部关闭"
                bordered: true
                focusable: true
                enabled: !root.busy
                onClicked: root.runAction("fuzzy-clear")
              }
              Button {
                text: "南方常用"
                bordered: true
                focusable: true
                enabled: !root.busy
                onClicked: root.runAction("fuzzy-preset-common")
              }
            }
          }

          // Fuzzy groups
          Column {
            width: parent.width
            spacing: Style.spacing.xs

            Repeater {
              model: root.fuzzyCategories

              delegate: Column {
                required property var modelData
                width: parent.width
                spacing: Style.spacing.xxs

                Text {
                  text: "［" + modelData.name + "］"
                  color: Qt.darker(Color.foreground, 1.3)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Flow {
                  width: parent.width
                  spacing: Style.spacing.xs

                  Repeater {
                    model: modelData.pairs

                    delegate: Rectangle {
                      id: fuzzyItem
                      required property var modelData
                      readonly property bool on: root.fuzzy[modelData.key] === true

                      function togglePair() {
                        if (!root.busy) root.apply("fuzzy." + modelData.key, !on ? "true" : "false")
                      }

                      activeFocusOnTab: true
                      Keys.onReturnPressed: togglePair()
                      Keys.onEnterPressed: togglePair()
                      Keys.onSpacePressed: togglePair()

                      width: Style.space(92)
                      height: Style.space(28)
                      radius: Style.cornerRadius
                      color: on ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.22) : Style.controlFill(false, mouse.containsMouse, Color.foreground, Color.accent)
                      border.width: 1
                      border.color: on || activeFocus ? Color.accent : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.22)

                      Text {
                        anchors.centerIn: parent
                        text: modelData.label
                        color: Color.foreground
                        opacity: fuzzyItem.on ? 1.0 : 0.75
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        font.bold: fuzzyItem.on
                      }

                      MouseArea {
                        id: mouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        enabled: !root.busy
                        onClicked: parent.togglePair()
                      }
                    }
                  }
                }
              }
            }
          }

          // ------------------------------------------------ 4. 词库与系统维护
          PanelSeparator { foreground: Color.foreground }

          PanelSectionHeader {
            text: "词库与系统维护"
            foreground: Color.foreground
          }

          Row {
            width: parent.width
            spacing: Style.spacing.sm

            Button {
              text: root.busy ? "…" : "刷新输入法主题"
              bordered: true
              focusable: true
              enabled: !root.busy
              onClicked: root.runAction("theme-regenerate")
            }

            Button {
              text: root.busy ? "…" : (root.confirmReset ? "⚠ 再次点击确认清空 (5s)" : "清空个人自学词库")
              bordered: true
              focusable: true
              enabled: !root.busy
              accent: root.confirmReset ? Color.urgent : Color.accent
              foreground: root.confirmReset ? Color.urgent : Color.foreground
              onClicked: {
                if (!root.confirmReset) {
                  root.confirmReset = true
                  root.notice = "清空不可撤销：将重置所有自学习词汇与个性化词频"
                  resetConfirmTimer.restart()
                } else {
                  root.confirmReset = false
                  resetConfirmTimer.stop()
                  root.runAction("userdict-reset")
                }
              }
            }
          }

          // Shortcuts note
          Text {
            width: parent.width
            text: "快捷键：Ctrl+Space 切换中英文 · Shift 临时英文 · Esc 取消输入"
            color: Qt.darker(Color.foreground, 1.6)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // Feedback toast / notice
          Text {
            width: parent.width
            text: root.notice
            visible: root.notice !== ""
            color: root.confirmReset ? Color.urgent : Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }

  Timer {
    id: resetConfirmTimer
    interval: 5000
    onTriggered: {
      root.confirmReset = false
      if (!root.busy && root.notice.indexOf("不可撤销") !== -1) root.notice = ""
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
    onExited: (code) => {
      if (setArgs.length === 3 && setArgs[1] === "action") {
        if (code === 0) {
          switch (setArgs[2]) {
            case "userdict-reset":
              root.notice = "个人自学词库与词频记录已清空"
              break
            case "theme-regenerate":
              root.notice = "主题已根据当前系统配色重新渲染"
              break
            case "fuzzy-clear":
              root.notice = "已关闭全部模糊音"
              break
            case "fuzzy-preset-common":
              root.notice = "已应用南方常用模糊音预设"
              break
            default:
              root.notice = "操作完成"
          }
        } else {
          root.notice = "操作失败（exit " + code + "）"
        }
      } else {
        root.notice = code === 0 ? "" : "写入配置失败（exit " + code + "）"
      }
      root.busy = false
      root.refreshState()
    }
  }
}
