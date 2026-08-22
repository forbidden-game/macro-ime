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
gh auth login            # 一次性：私有 repo 下载 LM 需要认证
git clone https://github.com/forbidden-game/omarime.git
cd omarime
./install.sh
```

install.sh 自动：
1. 检查依赖 (fcitx5, omarchy, omarchy-shell；预编译 addon 在 repo 里时无需编译工具链)
2. 备份现有 fcitx5 配置
3. 下载 LM (从 pinned GitHub Release, ~463MB, sha256 校验) 到 `~/.local/share/omarime/lib/`
4. 安装预编译 addon (repo `dist/`，缺失时回退本地 cmake 编译)
5. 安装主题 + 插件 + 配置后端
6. 设置 `LIBIME_MODEL_DIRS` + `FCITX_ADDON_DIRS` (systemd drop-in)
7. 应用主题 + 激活插件 + 重启 fcitx5/shell

### 离线安装

repo 是私有的，裸 `curl` 会 404——用 `gh`（自动带认证）下载：

```bash
# 在有网络的机器上 (需 gh auth login)
VERSION=$(cat VERSION)   # 例如 0.1.0
gh release download "v${VERSION}" --repo forbidden-game/omarime \
  --pattern 'zh_CN.lm' --pattern 'zh_CN.lm.predict' --dir /tmp/omarime-lm

# 在目标机器上 (U 盘/内网传输 /tmp/omarime-lm/)
./install.sh --lm-file /path/to/zh_CN.lm
# 或放到 repo 的 dist/ 目录
cp zh_CN.lm zh_CN.lm.predict dist/
./install.sh --offline
```

`--lm-file` 的 predict 文件约定为 `<LM文件>.predict`，缺失时只降级
cloud-pinyin 预测（安装会给出 warning）。

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

### 日常 CI (push to main)

- 校验 `dist/libomarime-state.so`：x86-64 ELF + **与源码同步**（源码 hash sidecar）
- `bash -n` + `shellcheck` + install.sh 可执行 smoke test

### 发版流程 (tag 触发)

```bash
# 1. 若改了 engine/omarime-state/ 源码，先重新构建 addon + 刷新 sidecar
cmake -S engine/omarime-state -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
cp build/libomarime-state.so dist/
sha256sum engine/omarime-state/omarime-state.cpp | cut -d' ' -f1 > dist/libomarime-state.so.src

# 2. 升级 VERSION 文件 (决定 install.sh 拉取哪个 release 的 LM/addon)
echo "0.1.1" > VERSION

# 3. 提交 + 打 tag (CI 验证通过后自动创建 DRAFT release, 附 .so)
git add -A && git commit -m "release: vX.Y.Z"
git tag vX.Y.Z && git push origin main vX.Y.Z

# 4. 手动上传 LM assets 到该 release (463MB 不适合 CI)
gh release upload vX.Y.Z zh_CN.lm zh_CN.lm.predict --repo forbidden-game/omarime

# 5. 取消 draft (CI 建的是 draft, 防止未验证 tag 直接发布)
#    注意: REST API 按 tag 查询不到 draft (404), 必须用数字 id:
NUM_ID=$(gh api repos/forbidden-game/omarime/releases \
  --jq '.[] | select(.tag_name=="vX.Y.Z") | .id')
gh api repos/forbidden-game/omarime/releases/$NUM_ID -X PATCH -f draft=false
```

用户侧更新：`git pull && ./install.sh`——install.sh 按 `VERSION` 拉取对应
release 的 LM，并做 sha256 校验。已安装的 LM 会跳过（除非删除旧文件或
升级 VERSION 后删除 `~/.local/share/omarime/lib/zh_CN.lm*`）。

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
