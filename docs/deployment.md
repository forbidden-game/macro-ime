# 引擎部署 — 生产架构 (v2)

## 设计原则

- **不修改系统文件**：所有 Macro IME 组件安装在用户目录下 (`~/.local/share/macro-ime/`)
- **不需要 root**：LM 通过 `LIBIME_MODEL_DIRS` 环境变量注入，不覆盖 `/usr/lib/libime/`
- **开箱即用**：公开 Release + `curl` 下载固定模型资产，不需要 GitHub 登录
- **明确支持面**：Omarchy 4.x / x86-64 / Fcitx Core ABI 7
- **可完整回滚**：`install.sh --undo` 恢复所有修改

## 文件布局

```
~/.local/share/macro-ime/
├── lib/
│   ├── zh_CN.lm              # E6 语言模型 (463MB)
│   ├── zh_CN.lm.predict      # 预测索引 (3.9MB)
│   ├── model-manifest.json   # 已安装模型版本+sha256 (更新判定依据)
│   └── fcitx5/
│       └── libmacro-ime-state.so  # 事件 addon (预编译)
├── bin/
│   └── macro-ime-config        # 设置面板后端
├── themes/
│   ├── macro-ime-theme         # 主题生成器
│   └── template/             # SVG 模板
└── backup/                   # 安装前备份 (undo 用)

~/.local/share/fcitx5/
├── addon/
│   └── macro-ime-state.conf    # addon 注册
└── themes/
    └── macro-ime/              # 生成的主题 (live)

~/.config/systemd/user/omarchy-fcitx5.service.d/
└── macro-ime-state.conf        # systemd drop-in:
                              #   FCITX_ADDON_DIRS → 加载 addon
                              #   LIBIME_MODEL_DIRS → 加载 LM

~/.cache/macro-ime/v0.1.1/
├── zh_CN.lm                  # 已校验的公开下载缓存
└── zh_CN.lm.predict
```

## LM 加载机制

libime 的 `DefaultLanguageModelResolver` 按 `LIBIME_MODEL_DIRS` 环境变量
指定的目录列表（冒号分隔）搜索 `<dir>/zh_CN.lm`。Macro IME 通过 systemd
user drop-in 设置：

```ini
[Service]
Environment="LIBIME_MODEL_DIRS=%h/.local/share/macro-ime/lib"
```

fcitx5 启动后，pinyin addon 在 `~/.local/share/macro-ime/lib/` 找到
`zh_CN.lm`，优先于系统默认的 `/usr/lib/libime/zh_CN.lm`。

**不需要写自定义 addon，不需要 LD_PRELOAD，不需要 patch 系统文件。**

## 部署步骤 (可复现)

### 首次安装

```bash
git clone https://github.com/forbidden-game/macro-ime.git
cd macro-ime
./install.sh
```

install.sh 自动：
1. 检查 Omarchy 4.x、x86-64、所需公开命令和 systemd user unit
2. 用 `ldd -r` 在任何配置写入前验证预编译 addon 的 Fcitx ABI
3. 解析 LM：固定到公开的模型 release（内置 URL + SHA-256）/
   已校验缓存 / dist/ / --lm-file，
   并依据 model-manifest.json 判定是否已安装且一致
4. 安装预编译 addon；普通用户无需编译工具链
5. 安装主题 + 插件 + 配置后端（插件安装前备份既有目录）
6. 事务提交：stop fcitx5 → 备份/编辑配置 + 写入 LM + manifest
   → restart fcitx5（失败时自动恢复服务）
7. 应用主题 + 激活插件 + 重启 shell，并通过**健康检查**：
   服务 active → addon 已加载 → state 文件实时写入

### 离线安装

```bash
# 在有网络的机器上，无需 GitHub 登录
curl -fLO https://github.com/forbidden-game/macro-ime/releases/download/v0.1.1/zh_CN.lm
curl -fLO https://github.com/forbidden-game/macro-ime/releases/download/v0.1.1/zh_CN.lm.predict

# 在目标机器上（U 盘/内网传输）
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

恢复所有 fcitx5 配置、移除 Macro IME 文件、恢复安装前已有的
插件目录及其启用状态、重启 fcitx5。

## 语言模型更新

**LM 资产不随每个 release 重复上传**：install.sh 明确固定模型所属的
release、公开下载 URL 和 SHA-256。模型没变化时继续引用原 release；
模型变化时更新安装器中的 `MODEL_RELEASE` 和两个 digest。

LM 由 `~/.local/share/macro-ime/lib/model-manifest.json` 跟踪：

```json
{
  "release": "v0.1.1",     // 安装器固定的公开模型 release
  "source": "release",     // release | lm-file | dist
  "files": {
    "zh_CN.lm": {"sha256": "…", "bytes": 463166204},
    "zh_CN.lm.predict": {"sha256": "…", "bytes": 3901025}
  }
}
```

更新流程（模型真的变化时）：

1. 训练新模型 (kenlm → ARPA → `libime_slm_build_binary`)
2. 生成预测索引 (`libime_prediction`)
3. 上传到**新 release**（`gh release upload <新tag> zh_CN.lm zh_CN.lm.predict`）
4. 更新 `install.sh` 中的 `MODEL_RELEASE`、`LM_SHA256` 和
   `LM_PREDICT_SHA256`
5. 用户重新运行 `install.sh` → 固定版本/digest 与 manifest
   不一致 → 自动下载并替换旧 LM

已有 LM 只在 `manifest.release == MODEL_RELEASE` 且文件与安装器内置
SHA-256 全部匹配时才跳过。旧安装（无 manifest）会先比对已有文件，
一致则只补写 manifest（无需重下 463MB）。

## CI / 发布

### 日常 CI (push to main)

- 校验 `dist/libmacro-ime-state.so`：x86-64 ELF、NEEDED 依赖集合
  (libFcitx5Core.so.7 / Config.so.6 / Utils.so.2)、**与源码同步**
  （聚合 hash sidecar：cpp + CMakeLists + conf.in）
- 在 Arch Linux 构建环境中重新编译 release addon，并验证 Fcitx Core
  ABI 仍为 7；ABI 变化会让 CI fail-closed
- 通过 GitHub 公共 API 核对模型资产 digest 与安装器固定值
- `bash -n` + `shellcheck`（install.sh / macro-ime-config / macro-ime-theme / hook）
- install.sh 可执行 smoke test（--help、非法参数拒绝、函数先定义回归）

### 发版流程 (tag 触发)

```bash
# 1. 若改了 engine/macro-ime-state/ 源码，先重新构建 addon + 刷新 sidecar
cmake -S engine/macro-ime-state -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
cp build/libmacro-ime-state.so dist/
sha256sum engine/macro-ime-state/macro-ime-state.cpp \
          engine/macro-ime-state/CMakeLists.txt \
          engine/macro-ime-state/macro-ime-state.conf.in \
  | sha256sum | cut -d' ' -f1 > dist/libmacro-ime-state.so.src

# 2. 升级 VERSION 文件（应用版本；模型版本由 install.sh 单独固定）
echo "X.Y.Z" > VERSION

# 3. 提交 + 打 tag（CI 在 Arch 环境重编译并附上正确命名的 .so）
git add -A && git commit -m "release: vX.Y.Z"
git tag vX.Y.Z && git push origin main vX.Y.Z

# 4. LM 资产：仅当模型内容变化时才上传
gh release upload vX.Y.Z zh_CN.lm zh_CN.lm.predict --repo forbidden-game/macro-ime
#    然后更新 install.sh 中固定的 MODEL_RELEASE 和 SHA-256

# 5. 取消 draft (CI 建的是 draft, 防止未验证 tag 直接发布)
#    注意: REST API 按 tag 查询不到 draft (404), 必须用数字 id:
NUM_ID=$(gh api repos/forbidden-game/macro-ime/releases \
  --jq '.[] | select(.tag_name=="vX.Y.Z") | .id')
gh api repos/forbidden-game/macro-ime/releases/$NUM_ID -X PATCH -f draft=false
```

用户侧更新：`git pull && ./install.sh`。安装器按固定公开 URL 下载，
使用内置 SHA-256 **fail-closed** 校验，然后写入 manifest。已安装且
manifest 与固定模型 release 一致的 LM 会跳过。

## 依赖声明

### 运行时 (installer 强制检查)

| 依赖 | 检查方式 | 用途 |
|---|---|---|
| fcitx5 | `command -v fcitx5` | IM 框架 |
| fcitx5-chinese-addons | `/usr/share/fcitx5/addon/pinyin.conf` | pinyin 引擎 (LM 真正生效的前提) |
| fcitx5-remote | `command -v` | 指示器/开关 |
| omarchy / omarchy-shell | `command -v` | 插件与 CLI |
| jq / busctl | `command -v` | 设置面板后端 |
| hyprctl / fc-match | `command -v` | 主题生成器 |
| curl | 按需检查 | 公开模型下载 |
| systemd --user | — | fcitx5 service + drop-in |

构建时（仅显式 `--build-from-source` 开发模式）：

| 依赖 | 用途 |
|---|---|
| cmake >= 3.20 | 构建 addon |
| C++20 compiler | 构建 addon |
| Fcitx5Core headers | 构建 addon |

运行时不需要 cmake/c++/headers。
