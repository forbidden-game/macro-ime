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
  property bool cloud: false
  property string correction: "None"
  property var fuzzy: ({})
  property int userModelWeight: 20
  property bool busy: false
  property bool confirmReset: false
  property string notice: ""

  readonly property var fuzzyPairs: [
    { key: "an_ang",   label: "an=ang" },
    { key: "en_eng",   label: "en=eng" },
    { key: "in_ing",   label: "in=ing" },
    { key: "ian_iang", label: "ian=iang" },
    { key: "uan_uang", label: "uan=uang" },
    { key: "c_ch",     label: "c=ch" },
    { key: "s_sh",     label: "s=sh" },
    { key: "z_zh",     label: "z=zh" },
    { key: "l_n",      label: "l=n" },
    { key: "f_h",      label: "f=h" },
    { key: "l_r",      label: "l=r" },
    { key: "v_u",      label: "v=u" },
    { key: "u_ou",     label: "u=ou" }
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
      width: Math.min(520, panel.width - Style.space(40))
      height: Math.min(contentCol.implicitHeight + Style.space(44), panel.height - Style.space(40))
      radius: Style.cornerRadius
      color: Color.popups.background
      border.width: Math.max(1, Style.space(2))
      border.color: Color.popups.border

      Column {
        id: contentCol
        anchors.centerIn: parent
        width: parent.width - Style.space(44)
        spacing: Style.spacing.md

        // header
        Item {
          width: parent.width
          height: titleText.implicitHeight

          Text {
            id: titleText
            text: "omarime · 中文输入"
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
            anchors.left: parent.left
          }

          Text {
            text: "✕"
            color: Color.foreground
            opacity: 0.6
            font.pixelSize: Style.font.subtitle
            anchors.right: parent.right
            anchors.verticalCenter: titleText.verticalCenter

            MouseArea {
              anchors.fill: parent
              anchors.margins: -Style.space(8)
              cursorShape: Qt.PointingHandCursor
              onClicked: root.close()
            }
          }
        }

        Toggle {
          width: parent.width
          label: "中文输入"
          description: "当前输入状态 · Ctrl+Space 切换"
          checked: root.imActive
          enabled: !root.busy
          onClicked: root.apply("im.active", !root.imActive ? "true" : "false")
        }

        Toggle {
          width: parent.width
          label: "竖排候选"
          description: "候选词纵向排列"
          checked: root.vertical
          enabled: !root.busy
          onClicked: root.apply("candidates.vertical", !root.vertical ? "true" : "false")
        }

        Toggle {
          width: parent.width
          label: "云拼音"
          description: "联网补充首候选 · 隐私优先，默认关"
          checked: root.cloud
          enabled: !root.busy
          onClicked: root.apply("cloud.enabled", !root.cloud ? "true" : "false")
        }

        // correction segmented
        Column {
          width: parent.width
          spacing: Style.spacing.xs

          Text {
            text: "拼音纠错（键盘邻键）"
            color: Color.foreground
            opacity: 0.85
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Row {
            spacing: Style.spacing.sm

            Button {
              text: "关"
              selected: root.correction === "None"
              focusable: true
              enabled: !root.busy
              onClicked: root.apply("correction", "None")
            }
            Button {
              text: "QWERTY 邻键"
              selected: root.correction === "QWERTY"
              focusable: true
              enabled: !root.busy
              onClicked: root.apply("correction", "QWERTY")
            }
          }
        }

        // user model weight
        Column {
          width: parent.width
          spacing: Style.spacing.xs

          Text {
            text: "用户模型强度（影响缩写候选排序）"
            color: Color.foreground
            opacity: 0.85
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Row {
            spacing: Style.spacing.sm

            Button {
              text: "关"
              selected: root.userModelWeight === 0
              focusable: true
              enabled: !root.busy
              onClicked: root.apply("usermodel.weight", "0")
            }
            Button {
              text: "弱"
              selected: root.userModelWeight === 10
              focusable: true
              enabled: !root.busy
              onClicked: root.apply("usermodel.weight", "10")
            }
            Button {
              text: "默认"
              selected: root.userModelWeight === 20
              focusable: true
              enabled: !root.busy
              onClicked: root.apply("usermodel.weight", "20")
            }
            Button {
              text: "中"
              selected: root.userModelWeight === 50
              focusable: true
              enabled: !root.busy
              onClicked: root.apply("usermodel.weight", "50")
            }
            Button {
              text: "强"
              selected: root.userModelWeight === 100
              focusable: true
              enabled: !root.busy
              onClicked: root.apply("usermodel.weight", "100")
            }
          }
        }

        // fuzzy grid
        Column {
          width: parent.width
          spacing: Style.spacing.xs

          Text {
            text: "模糊音（全部关闭时最精准）"
            color: Color.foreground
            opacity: 0.85
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Grid {
            width: parent.width
            columns: 4
            columnSpacing: Style.spacing.xs
            rowSpacing: Style.spacing.xxs

            Repeater {
              model: root.fuzzyPairs

              delegate: Rectangle {
                required property var modelData
                readonly property bool on: root.fuzzy[modelData.key] === true

                function togglePair() {
                  if (!root.busy) root.apply("fuzzy." + modelData.key, !on ? "true" : "false")
                }

                activeFocusOnTab: true
                Keys.onReturnPressed: togglePair()
                Keys.onEnterPressed: togglePair()
                Keys.onSpacePressed: togglePair()

                width: (parent.width - (parent.columns - 1) * parent.columnSpacing) / parent.columns
                height: Style.space(30)
                radius: Style.cornerRadius
                color: on ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.20) : Style.controlFill(false, mouse.containsMouse, Color.foreground, Color.accent)
                border.width: 1
                border.color: on || activeFocus ? Color.accent : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.25)

                Text {
                  anchors.centerIn: parent
                  text: modelData.label
                  color: Color.foreground
                  opacity: root.on ? 1.0 : 0.75
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
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

        // actions
        Row {
          spacing: Style.spacing.sm

          Button {
            text: busy ? "…" : "重新生成主题"
            bordered: true
            focusable: true
            enabled: !root.busy
            onClicked: root.runAction("theme-regenerate")
          }
          Button {
            text: busy ? "…" : (root.confirmReset ? "再次点击确认清空" : "清空用户词典")
            bordered: true
            focusable: true
            enabled: !root.busy
            onClicked: {
              if (!root.confirmReset) {
                root.confirmReset = true
                root.notice = "清空不可撤销；请在 5 秒内再次点击确认"
                resetConfirmTimer.restart()
              } else {
                root.confirmReset = false
                resetConfirmTimer.stop()
                root.runAction("userdict-reset")
              }
            }
          }
        }

        Text {
          width: parent.width
          text: root.notice
          visible: root.notice !== ""
          color: Color.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }

  Timer {
    id: resetConfirmTimer
    interval: 5000
    onTriggered: {
      root.confirmReset = false
      if (!root.busy) root.notice = ""
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
          root.cloud = s.cloud === true
          root.correction = String(s.correction || "None")
          root.fuzzy = s.fuzzy || {}
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
        root.notice = code === 0 ? (setArgs[2] === "userdict-reset" ? "用户词典已清空" : "主题已重新生成") : "操作失败（exit " + code + "）"
      } else {
        root.notice = code === 0 ? "" : "写入失败（exit " + code + "）"
      }
      root.busy = false
      root.refreshState()
    }
  }
}
