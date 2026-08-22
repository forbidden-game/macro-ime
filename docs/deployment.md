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
│   ├── model-manifest.json   # 已安装模型版本+sha256 (更新判定依据)
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
1. 检查依赖 (fcitx5 + pinyin addon, omarchy, omarchy-shell, jq/busctl/hyprctl；
   预编译 addon 在 repo 里时无需编译工具链)
2. 解析 LM：自动定位最新带 `zh_CN.lm` 资产的 release
   （sha256 fail-closed 校验）/ dist/ / --lm-file，
   并依据 model-manifest.json 判定是否已安装且一致
3. 安装预编译 addon（含 ldd -r ABI 预检；失败回退本地 cmake 编译）
4. 安装主题 + 插件 + 配置后端（插件安装前备份既有目录）
5. 事务提交：stop fcitx5 → 备份/编辑配置 + 写入 LM + manifest
   → restart fcitx5（失败时自动恢复服务）
6. 应用主题 + 激活插件 + 重启 shell，并通过**健康检查**：
   服务 active → addon 已加载 → state 文件实时写入

### 离线安装

repo 是私有的，裸 `curl` 会 404——用 `gh`（自动带认证）下载：

```bash
# 在有网络的机器上 (需 gh auth login)—— 从持有 LM 的 release 下载
# （LM 不随每个版本重复上传；这条命令与 install.sh 的解析逻辑一致）
LM_TAG=$(gh api repos/forbidden-game/omarime/releases --paginate \
  --jq '.[] | select(any(.assets[]?; .name == "zh_CN.lm")) | .tag_name' | head -1)
gh release download "$LM_TAG" --repo forbidden-game/omarime \
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

恢复所有 fcitx5 配置、移除 omarime 文件、恢复安装前已有的
插件目录及其启用状态、重启 fcitx5。

## 语言模型更新

**LM 资产不随每个 release 重复上传**：install.sh 自动解析“最新一个
带 `zh_CN.lm` 资产的 release”作为模型源（`resolve_lm_release`），
模型字节没变就永远从原 release 拉取，发版无需重新上传 463MB。

LM 由 `~/.local/share/omarime/lib/model-manifest.json` 跟踪：

```json
{
  "release": "v0.1.1",     // 实际持有该模型的 release（解析结果）
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
4. 用户重新运行 `install.sh` → 解析到新 release，digest 与 manifest
   不一致 → 自动下载并原子替换旧 LM

已有 LM 只在 `manifest.release == 解析出的 LM release` 且 sha256 全部
匹配时才跳过。旧安装（无 manifest）会先比对已有文件与当前 LM release
的 digest，一致则只补写 manifest（无需重下 463MB）。

## CI / 发布

### 日常 CI (push to main)

- 校验 `dist/libomarime-state.so`：x86-64 ELF、NEEDED 依赖集合
  (libFcitx5Core.so.7 / Config.so.6 / Utils.so.2)、**与源码同步**
  （聚合 hash sidecar：cpp + CMakeLists + conf.in）
- `bash -n` + `shellcheck`（install.sh / omarime-config / omarime-theme / hook）
- install.sh 可执行 smoke test（--help、非法参数拒绝、函数先定义回归）

### 发版流程 (tag 触发)

```bash
# 1. 若改了 engine/omarime-state/ 源码，先重新构建 addon + 刷新 sidecar
cmake -S engine/omarime-state -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
cp build/libomarime-state.so dist/
sha256sum engine/omarime-state/omarime-state.cpp \
          engine/omarime-state/CMakeLists.txt \
          engine/omarime-state/omarime-state.conf.in \
  | sha256sum | cut -d' ' -f1 > dist/libomarime-state.so.src

# 2. 升级 VERSION 文件 (决定 install.sh 拉取哪个 release 的 LM/addon，
#    也驱动用户的模型更新)
echo "0.1.1" > VERSION

# 3. 提交 + 打 tag (CI 验证通过后自动创建 DRAFT release, 附 .so)
git add -A && git commit -m "release: vX.Y.Z"
git tag vX.Y.Z && git push origin main vX.Y.Z

# 4. LM 资产：仅当模型内容变化时才上传（install.sh 自动解析最新
#    带 zh_CN.lm 的 release，未变化时无需重复上传 463MB）
gh release upload vX.Y.Z zh_CN.lm zh_CN.lm.predict --repo forbidden-game/omarime
#    （模型没变 → 跳过此步）

# 5. 取消 draft (CI 建的是 draft, 防止未验证 tag 直接发布)
#    注意: REST API 按 tag 查询不到 draft (404), 必须用数字 id:
NUM_ID=$(gh api repos/forbidden-game/omarime/releases \
  --jq '.[] | select(.tag_name=="vX.Y.Z") | .id')
gh api repos/forbidden-game/omarime/releases/$NUM_ID -X PATCH -f draft=false
```

用户侧更新：`git pull && ./install.sh`——install.sh 解析最新带
`zh_CN.lm` 的 release 作为模型源，sha256 **fail-closed** 校验（拿不到
digest 即失败，不降级为跳过），然后写入 manifest。已安装且
manifest 与该 release 一致的 LM 会跳过。

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
| systemd --user | — | fcitx5 service + drop-in |

构建时 (仅 fallback 本地编译):
| 依赖 | 用途 |
|---|---|
| cmake >= 3.20 | 构建 addon |
| C++20 compiler | 构建 addon |
| Fcitx5Core headers | 构建 addon |

运行时不需要 cmake/c++/headers。
