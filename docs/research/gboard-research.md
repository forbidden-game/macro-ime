# Gboard research program (黑盒研究计划)

目的：把 Gboard/谷歌拼音的"越用越好用"拆解成可实现的工程规格，用于校准
Macro IME 的 Phase 2（数据/LM）和 Phase 6（神经方向）。

## 铁律 (non-negotiable guardrails)

1. **只研究，不搬运。** Gboard 是专有软件。它的词库、语言模型、二进制、
   资源文件一律不得进入 Macro IME 仓库或派生数据。我们只提取**知识**：
   架构思路、文件格式特征、尺寸量级、行为规格。
2. `research/apk/` 已加入 `.gitignore`，任何 APK/解包产物永不 commit。
3. 行为结论必须可验证（可复现的输入→输出实验），不靠印象。

## 我们能从 APK 得到什么（预期管理）

| 内容 | 在哪 | 价值 |
|---|---|---|
| 原生库清单 (`lib*.so`)、大小 | base APK | 推断引擎构成（解码器/LM/声学?） |
| DEX 结构、类名 | base APK | 架构分层参考 |
| 内置资产 (字体/主题/小模型) | base APK | 尺寸量级感 |
| **简体中文语言包** | 运行时下载，存 app 私有目录 | ★ 模型格式/尺寸的真目标 |
| **用户自适应后的模型** | app 私有目录 | ★ "越用越好用"的实现证据 |

→ base APK 只有"目录级"情报；真货需要 root 过的 Android 模拟器
（google_apis 镜像支持 `adb root`）装 Gboard、下载中文包后 pull 私有数据。

## 获取路径

- **A. 手动下载 base APK（5 分钟，先做）**：浏览器开
  https://www.apkmirror.com/apk/google-inc/gboard/ （选 stable arm64-v8a）
  存到 `research/apk/gboard.apk`，然后告诉我路径。
  我用 `unzip -l` + 提取 manifest/资源做清单分析（无需 java/jadx）。
- **B. 模拟器深挖（可选，重）**：Android Studio AVD (Google APIs image,
  可 adb root) → 装 Gboard → 触发中文包下载 → pull 私有目录 → 只做格式/尺寸
  分析。
- **C. 你自己的手机**：Gboard 数据目录无 root 不可读，此路不通（adb backup
  已被 Google 禁用）。你的价值在下面"行为规格"部分当活体参照。

## 行为规格实验清单（用你日常的 Gboard 观察即可，我来整理成规格）

1. **候选数量与布局**：主候选几个？预测条（下一个词）何时出现？
2. **纠错激进程度**：打错拼音（如 `zhongguo` 打成 `zhonggu`、`zhangguo`）
   时第几候选开始出现纠错结果？
3. **缩写输入**：首字母缩写 (`bj`→北京?) 触发条件、排序规律。
4. **中英混输**：句子中打英文单词的体验；英文候选与中文候选如何共存。
5. **用户自适应可观察行为**：
   - 新造词/人名打几次后进首选？（估计：2-3 次）
   - 词频衰减：多久不用的词会掉出首选？
   - 删掉重选（负反馈）是否影响排序？
6. **标点/数字**：中文模式下标点全角规则、网址/邮箱自动半角？
7. **整句输入**：一次打多长的句子体验最好？回退（退格）时如何重新切分？

## 量化基准（来自公开论文，见 research.md）

- Google IME 在 **PD 数据集**（人民日报 92-98，2000 测试句）：
  **P@1 = 70.9 / P@2 = 78.3 / P@3 = 82.3**（arXiv:2203.00249 实测）
- PinyinGPT（学术 SOTA，beam=16）：P@1 = 73.15 / P@2 = 84.10 / P@3 = 85.45
- **Macro IME 目标线：trigram 版 P@1 ≥ 60（超 2008 老 LM），神经版 ≥ 70.9
  （宣称"Gboard 级"前必须过这条线）**
- PD 测试集可直接用于我们 eval harness 的新闻域基准（训练集语料注意
  时代偏差，另建现代语料测试桶）。

## 已知架构情报（论文 + 公开资料）

- Google 输入法引擎：句子级解码 + n-gram/neural LM + 用户模型在线插值
  （与我们 libime 路线同构；libime = 开源世界对这套架构的实现）
- 缩写拼音是难点：一串首字母映射到指数级候选组合；GPT 方案用
  pinyin-constrained vocabulary 解决（Phase 6 参考）
- 推理延迟：6 层 transformer 比 12 层快 ~30%，精度略降 → Phase 6 的
  模型尺寸起点：6 层级、int8、CPU 实时
