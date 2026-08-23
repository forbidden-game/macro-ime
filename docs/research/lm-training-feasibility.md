# 语言模型自训练可行性研究（2026-02）

结论先行：**工具链风险已排除，集成路径与官方完全同构；真正的工作量在语料清洗
和分词对齐。难度评级：中。本机资源足够。**

## 1. 集成路径：已实锤（最高风险项解除）

libime 官方构建文件（`tools/CMakeLists.txt` + `data/CMakeLists.txt`）显示：

```cmake
# libime_slm_build_binary 就是 kenlm 的 build_binary（直接编译 kenlm/lm/build_binary_main.cc）
COMMAND LibIME::slm_build_binary -s -a 22 -q 4 trie lm_sc.arpa sc.lm
```

- libime **内嵌 kenlm**，LM 格式 = kenlm trie，4bit 量化（`-q 4`）
- 官方管线：ARPA 文本 → `build_binary trie` → 二进制 LM
- 我们的自训管线与官方**同一条路**：`kenlm lmplz -o 3` 产 ARPA → 同一命令产二进制
- 另有 `sc.lm.predict`（预测文件）由同一 ARPA 派生，需一并重生成

## 2. 现役 LM 尸检（我们要打败的对手有多弱）

从 fcitx 官方服务器下载了现役 `lm_sc.arpa`（2026-06 打包版）：

| 指标 | 数值 | 点评 |
|---|---|---|
| ARPA 文件大小 | **188 MB** | 极小 |
| unigram | 270,714 | 词表 27 万 |
| bigram | 4,789,953 | |
| trigram | **2,189,434** | 仅 219 万三元组 |

现代标准下这是玩具尺寸——10GB 文本训出的 trigram 通常有 5000 万~2 亿条。
推断其训练语料约 1~2GB、且是 2008 年前后的新闻/网页。
**我们用 20~100 倍的现代语料碾压它是大概率事件，不是赌注。**

## 3. 语料情况（够用，且有梯度）

| 语料 | 规模 | 性质 | 许可/获取 | 用途 |
|---|---|---|---|---|
| CLUECorpus2020 | 100GB（Small 版 14GB）| 清洗过的 Common Crawl 中文网页 | 开放下载，研究友好 | 主力 |
| WuDaoCorpora 2.0 Base | 200GB（压缩 64GB）| 高质量网页 | BAAI 注册协议 | 主力补充 |
| THUCNews | 74 万篇新浪新闻 (05-11) | 新闻 | 免费研究用 | 正式域 |
| SogouCA | 全网新闻 2012 | 新闻 | mini 开放/完整申请 | 正式域 |
| zhwiki 月度 dump | ~1.5GB 文本 | 百科 | CC BY-SA，最干净 | 实体/词表 |
| OPUS OpenSubtitles zh | 数 GB | 口语对白 | 开放（OPUS 分发）| **口语流**（Gboard 手感的关键）|
| ChineseWebText 2.0 | 大规模+质量分 | 网页 | 论文附带开放 | 按质量分筛选 |

分层策略：口语（字幕）权重调高——输入法打的是口语，不是书面语；
百科管实体覆盖；新闻管正式表达。

## 4. 管线设计（含全项目最关键的技术细节）

```
原始语料 → 清洗(去重/去HTML/繁转简) → 【分词】→ kenlm lmplz -o3 → ARPA
                                                              → slm_build_binary trie -q4 → macro-ime.lm
                                                              → libime_prediction → macro-ime.lm.predict
```

⚠️ **词表对齐问题（本项目最重要的技术细节）：**
libime 解码器按**词典的词条**切格，LM 的分词粒度必须与词典一致，
否则打分错位。解法：先定词典词表 → 用该词表驱动分词（最大匹配+jieba
混合，OOV 回退到单字）→ 再训 LM。词典和 LM 是一对，永远一起发布。

## 5. 计算预算 vs 本机（16 核 / 30GB RAM / 683GB 空闲盘）

| 步骤 | 估算 | 可行性 |
|---|---|---|
| 语料下载+清洗 | 20~40GB 原始 → 15~25GB 净文本；数小时脚本活 | ✅ 磁盘充裕 |
| 分词（并行 16 核）| 15~25GB，1~3 小时 | ✅ |
| kenlm lmplz trigram | RAM 敏感；30GB 内存配 `-S 70%` + 剪枝可吃 ~15GB 语料；更大则分片/子采样 | ✅ 需调参 |
| build_binary -q 4 | 分钟级，产物预计 300MB~1.5GB | ✅ |
| eval 跑分 | 自建 harness，CPU 秒级/千句 | ✅ |

## 6. 难度评级汇总

| 环节 | 难度 | 说明 |
|---|---|---|
| 工具链/格式转换 | ★☆☆☆☆ 已排除 | 与官方同构，命令级确认 |
| 语料获取 | ★★☆☆☆ | 都能拿到，注册流程繁琐而已 |
| 清洗/去重/繁简 | ★★★☆☆ | 体力活+细节，脚本工程 |
| **分词与词表对齐** | ★★★★☆ | **核心难点**，决定成败 |
| kenlm 调参 | ★★☆☆☆ | 剪枝/量化平衡，有成熟方法论 |
| eval harness | ★★★☆☆ | 要建得认真，否则一切无从谈起 |
| 用户模型验证 | ★★★☆☆ | libime 有实现，效果待实测（独立于训练线）|

## 7. 未决问题

1. fcitx5-chinese-addons 的 LM 路径是编译期定的（`/usr/share/libime/pinyin/sc.lm`）：
   v1 替换系统文件（脏但立即可试），v2 写自己的 addon 干净加载（产品形态）
2. Gboard 运行时模型若逆向成功，作为额外数据源并入对比评测（用户已拍板允许）
3. PD 测试集需学术渠道申请；先用自建测试桶起步，PD 到手后补基准分

## 8. Phase 2 启动顺序（spike 优先）

1. Day 1 spike：拿 zhwiki+THUCNews（~3GB）走通全管线 → 出第一颗 macro-ime.lm
   → 在 50 个手工测试句上对比老 LM（哪怕只打平，路径即验证）
2. 然后上大语料（CLUE Small 14GB + 字幕 + 悟道子集）正式训练
3. 词典 v1 与分词器同步迭代
