# 引擎部署 — 生产架构 (v2)

## 设计原则

- **不修改系统文件**：所有 omarime 组件安装在用户目录下 (`~/.local/share/omarime/`)
- **不需要 root**：LM 通过 `LIBIME_MODEL_DIRS` 环境变量注入，不覆盖 `/usr/lib/libime/`
- **可完整回滚**：`install.sh --undo` 恢复所有修改

## 文件布局

```
~/.local/share/omarime/
├── lib/
│   ├── zh_CN.lm              # E6 语言模型 (463MB)
│   ├── zh_CN.lm.predict      # 预测索引 (3.9MB)
│   └── fcitx5/
│       └── libomarime-state.so  # 事件 addon (预编译)
├── bin/
│   └── omarime-config        # 设置面板后端
├── themes/
│   ├── omarime-theme         # 主题生成器
│   └── template/             # SVG 模板
└── backup/                   # 安装前备份 (undo 用)

~/.local/share/fcitx5/
├── addon/
│   └── omarime-state.conf    # addon 注册
└── themes/
    └── omarime/              # 生成的主题 (live)

~/.config/systemd/user/omarchy-fcitx5.service.d/
└── omarime-state.conf        # systemd drop-in:
                              #   FCITX_ADDON_DIRS → 加载 addon
                              #   LIBIME_MODEL_DIRS → 加载 LM
```

## LM 加载机制

libime 的 `DefaultLanguageModelResolver` 按 `LIBIME_MODEL_DIRS` 环境变量
指定的目录列表（冒号分隔）搜索 `<dir>/zh_CN.lm`。omarime 通过 systemd
user drop-in 设置：

```ini
[Service]
Environment="LIBIME_MODEL_DIRS=%h/.local/share/omarime/lib"
```

fcitx5 启动后，pinyin addon 在 `~/.local/share/omarime/lib/` 找到
`zh_CN.lm`，优先于系统默认的 `/usr/lib/libime/zh_CN.lm`。

**不需要写自定义 addon，不需要 LD_PRELOAD，不需要 patch 系统文件。**

## 部署步骤 (可复现)

### 首次安装

```bash
git clone https://github.com/forbidden-game/omarime.git
cd omarime
./install.sh
```

install.sh 自动：
1. 检查依赖 (fcitx5 >= 5.1, omarchy, omarchy-shell)
2. 备份现有 fcitx5 配置
3. 下载 LM (从 GitHub Release, ~463MB) 到 `~/.local/share/omarime/lib/`
4. 安装预编译 addon (从 repo dist/ 或 GitHub Release)
5. 安装主题 + 插件 + 配置后端
6. 设置 `LIBIME_MODEL_DIRS` + `FCITX_ADDON_DIRS` (systemd drop-in)
7. 应用主题 + 激活插件 + 重启 shell

### 离线安装

```bash
# 在有网络的机器上下载 LM
curl -LO <github-release-url>/zh_CN.lm
curl -LO <github-release-url>/zh_CN.lm.predict

# 在目标机器上
./install.sh --lm-file /path/to/zh_CN.lm
# 或放到 repo 的 dist/ 目录
cp zh_CN.lm zh_CN.lm.predict dist/
./install.sh --offline
```

### 跳过 LM (只装 UI)

```bash
./install.sh --skip-lm
```

### 回滚

```bash
./install.sh --undo
```

恢复所有 fcitx5 配置、移除 omarime 文件、禁用插件、重启 fcitx5。

## 语言模型更新

LM 不随代码更新。更新流程：

1. 训练新模型 (kenlm → ARPA → `libime_slm_build_binary`)
2. 生成预测索引 (`libime_prediction`)
3. 上传到 GitHub Release (替换 asset)
4. 用户重新运行 `install.sh` (会检测已有 LM 并跳过，除非删除旧文件)

## CI / 发布

- **push to main**: 构建 addon → upload artifact
- **git tag v\*.\*.\***: 构建 addon → 创建 GitHub Release (draft)
- LM 文件手动上传到 Release (太大不适合 CI 自动处理)

## 依赖声明

| 依赖 | 最低版本 | 来源 | 用途 |
|---|---|---|---|
| fcitx5 | 5.1 | Omarchy 系统包 | IM 协议 + pinyin addon |
| libime | 1.1 | 随 fcitx5-chinese-addons | 解码引擎 + LM 加载 |
| omarchy | 4.x | Omarchy 系统 | CLI + plugin API |
| omarchy-shell | 4.x | Omarchy 系统 | Quickshell UI 宿主 |
| systemd --user | — | 系统 | fcitx5 service + drop-in |

构建时 (仅 fallback 本地编译):
| 依赖 | 用途 |
|---|---|
| cmake >= 3.20 | 构建 addon |
| C++20 compiler | 构建 addon |
| Fcitx5Core headers | 构建 addon |

运行时不需要 cmake/c++/headers。
