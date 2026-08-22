# omarime

为 Omarchy 打造的一等中文输入体验：**现代 libime 语言模型、越用越懂你的
用户模型，以及真正跟随 Omarchy 的候选窗口与控制界面。**

当前生产引擎：`fcitx5-pinyin (libime) + omarime E6 LM`。
E6 评测准确率 89.6%（stock 81.0%）；主题、bar 指示器和设置面板已上线。
详细研究、架构与路线图见 [PLAN.md](PLAN.md)。

## 三个承诺

1. **好输入**：句级解码、用户模型、可选 QWERTY 邻键纠错、现代语料语言模型。
2. **好切换**：保留用户选择的 `Ctrl+Space`；bar 显示 中/A，左键切换，状态变化有 OSD。
3. **好看且原生**：候选窗自动读取 Omarchy `colors.toml`、Hyprland 圆角和桌面字体；
   右键 bar 指示器打开原生设置面板。

## 安装

```bash
git clone <this-repo> && cd omarime
./install.sh          # 主题 + hook + 配置后端 + shell 插件
./install.sh --undo   # 恢复安装前 fcitx5 配置并移除所有文件
```

引擎 E6 的部署与回滚见 [docs/deployment.md](docs/deployment.md)。总安装器不会替换
系统 `/usr/lib/libime/zh_CN.lm`；语言模型仍按该文档单独部署。

## 已实现组件

| 路径 | 功能 |
|---|---|
| `lm/`, `eval/` | E6 语言模型训练与回归评测 |
| `themes/` | 从当前 Omarchy 主题生成 fcitx5 classicui SVG 主题；theme-set 自动跟随 |
| `plugins/omarime.indicator/` | bar 中/A 状态；左键切换、右键设置、直接 IPC OSD |
| `plugins/omarime.settings/` | 云拼音、纠错、横竖排、13 组模糊音、主题重生成、用户词典重置 |
| `bin/omarime-config` | 设置面板后端；通过 Controller1.SetConfig 原子更新内存与文件 |
| `docs/` | 引擎部署、实验记录与研究结论 |

## 设置面板

右键 bar 上的 **中/A**，或运行：

```bash
omarchy-shell shell toggle omarime.settings '{}'
```

普通设置通过 DBus 原子生效、无需重启；仅用户词典重置和主题素材重载会短暂重启 fcitx5。
