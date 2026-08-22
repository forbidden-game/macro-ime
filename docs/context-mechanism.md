# 上下文机制 — 为什么同一串拼音，在不同上下文里候选不同

> 本文拆解 omarime（fcitx5-pinyin + libime + E6 三阶 LM + 用户历史）里
> "上下文如何影响候选排序" 的完整机制：打分管线、三个相互独立的上下文入口、
> 各自的代码路径与开关，以及 omarime 为什么默认「句间关、句内开、用户历史最强」。
>
> 行号基于 `libime v1.1.15` 与 `fcitx5-chinese-addons v5.1.13`（+ omarime 的
> `UserModelWeight` patch）。源码快照在 `/tmp/libime-src`、`/tmp/fcitx5-ca-src`。

---

## 0. 一句话结论（TL;DR）

候选排序由**束搜索（beam search）**驱动，每个候选节点的分数是：

```
节点分数 = max(各父节点分数 + 语言模型从父状态到该词的转移分) + 节点自身代价
```

其中「语言模型转移分」是唯一被上下文影响的部分。上下文有**三个独立入口**，
互不重叠、各自可单独关掉：

| 入口 | 含义 | 开关 | omarime 默认 |
|---|---|---|---|
| **A. 句间上下文** | 上一句上屏的词，引导本句候选 | `KeepCurrentContext` | **关** |
| **B. 句内上下文** | 本句里已选定的词，引导后续候选 | 无开关（设计上恒开） | 开 |
| **C. 用户历史** | 你个人历史上「前词→本词」的共现，叠加进打分 | `UserModelWeight` | 用户自定（本机 100） |

「同拼音候选漂移」的主因是 **A**——关掉它，同一串拼音的候选就稳定了；
B 是"长句里越打越准"的来源，保留；C 是"越用越懂你"，只加分不降分。

---

## 1. 组件与文件位置

| 层 | 路径 | 职责 |
|---|---|---|
| 输入法插件（addon） | `im/pinyin/`（fcitx5-chinese-addons） | UI、配置、状态管理、上屏/学习触发 |
| 解码引擎 | `src/libime/`（libime） | 束搜索、语言模型、上下文状态 |
| 基础 LM（E6） | `/usr/lib/libime/zh_CN.lm` | kenlm 三阶（trigram），442MB，8300 万句，P@1=89.6% |
| 用户词典 | `~/.local/share/fcitx5/pinyin/user.dict` | 你学会的词 → 作为候选节点出现 |
| 用户历史 | `~/.local/share/fcitx5/pinyin/user.history` | 你「前词→本词」的 bigram → 叠加进打分 |
| 引擎配置 | `~/.config/fcitx5/conf/pinyin.conf` | `KeepCurrentContext` / `UserModelWeight` 等 |

> 注意区分两个"用户"文件：
> - **user.dict**（用户词典）决定*哪些词会作为候选出现*（带一个节点代价 cost）。
> - **user.history**（用户历史）决定*这些候选怎么排序*（bigram，叠加进 LM 分）。
> `UserModelWeight` 只作用于后者。

---

## 2. 打分管线：束搜索

文件：`libime/core/decoder.cpp`

解码在一张 **lattice**（分段图）上做束搜索。对图中每个候选节点 `node`：

```cpp
// decoder.cpp:211-229
for (auto &parent : searchFrom | take(beamSize)) {          // 只取 beam 内父节点
    auto score = parent.score() +
                model_->score(parent.state(), node, state); // 父分 + LM 转移分
    if (score > maxScore) { maxScore = score; maxNode = &parent; maxState = state; }
}
node.setScore(maxScore + node.cost());   // 最后加上节点自身代价
```

逐词展开：

```
node.score = max over parents ( parent.score + LM.score(parent.state → node) )
             + node.cost
```

- `parent.score`：沿路径累积的分数（每个词的分累加）。
- `LM.score(parent.state → node)`：**唯一被上下文影响的部分**，见 §3。
  它吃 `parent.state()`——一个携带「前面最近 2 个词」的 trigram 状态对象。
- `node.cost`：节点自身代价，来自词典查找（用户词典词、纠错候选等），
  **与上下文无关**。它决定"哪些词能进候选"，不参与上下文漂移。

> 所以：**上下文只通过 `LM.score` 这一项进入总分**。理解了 §3 和 §4，
> 就理解了全部。

---

## 3. 语言模型打分：基础 LM 与用户历史的插值

文件：`libime/core/userlanguagemodel.cpp`

`model_->score(...)` 实际是 `UserLanguageModel::score`（`userlanguagemodel.cpp:122-139`）：

```cpp
float UserLanguageModel::score(const State &state, const WordNode &word, State &out) {
    float base = LanguageModel::score(state, word, out);   // ① 基础 kenlm 三阶（E6）
    const auto *prev = wordFromState(state);               // 状态里最近的那个词
    float userScore = history_.scoreWithCode(prev, &word); // ② 用户历史 bigram
    // wa = log10(1-w), wb = log10(w)，w = UserModelWeight/100
    return std::max(base, sum_log_prob(base + wa_, userScore + wb_));
}
```

其中 `sum_log_prob(a, b) = log10(10^a + 10^b)`（对数空间插值，`userlanguagemodel.cpp:118-120`）。
展开成线性概率就是**经典插值**：

```
最终分 = max( 基础分,
              log10( (1-w)·10^基础分  +  w·10^用户分 ) )
        w = UserModelWeight / 100
```

三个要点：

1. **只加分，不降分。** 外层是 `max(base, interp)`——用户历史永远不可能把
   基础 LM 认为好的词排下去，只能把"你常用"的词顶上来。这是 C 入口
   "越用越顺、不会越用越歪"的数学保证。
2. **w 是插值权重。**
   - `w=0`：`max(base, base) = base`，用户历史完全失效（= 纯 E6）。
   - `w=1`：`max(base, userScore)`，用户历史有**完全覆盖权**（基础分只在它更高时兜底）。
   - 上游默认 `w=0.2`（`DEFAULT_USER_LANGUAGE_MODEL_USER_WEIGHT = 0.2`，
     `core/constants.h:18`），即 omarime patch 里的默认 20。
3. **`prev` 来自 state**：用户历史是 **bigram**，只看「最近 1 个前词 → 本词」，
   比基础 LM 的三阶窗口短。

### 用户历史 bigram 怎么算

文件：`libime/core/historybigram.cpp:660-686`（`scoreWithCode`）

```cpp
prev 为空 → "<s>"；cur 为空 → "<unk>"
pr = 0.8 · bigramFreq(prev,cur) / (unigramFreq(prev) + pool/2)   // 80% bigram
   + 0.2 · unigramFreq(cur)    / (unigramSize    + pool/2)       // 20% 一元平滑
pr = min(pr, 1.0)
if (pr == 0) return unknown_;   // 没见过 → 未知惩罚（负分）
return log10(pr);
```

- **add-α 平滑**：80% 走 bigram、20% 回落一元，`pool` 是平滑池权重，避免除零。
- **没见过的前后词对** → 返回 `unknown_`（一个负惩罚），即"没把握"。

---

## 4. 三个上下文入口（核心）

「上下文」在代码里不是一个东西，而是**三条互不相干的数据流**，各自喂给
§2 的 `LM.score`。理解它们的边界，就知道每个开关到底动了什么。

### 状态对象：上下文最终都汇进同一个 `State`

文件：`libime/pinyin/pinyincontext.cpp:581-602`（`PinyinContext::state`）

```cpp
State PinyinContext::state() const {
    State state = model->nullState();
    for (word : d->contextWords_)        // ① 句间：上一句的词
        state = LM.score(state, word);
    for (sel  : d->selected_)           // ② 句内：本句已选的词
        for (item : sel)
            state = LM.score(state, item.word_);
    return state;   // 一个 trigram 状态，喂给 §2/§3 的 LM.score
}
```

- `contextWords_` = **句间**（A），由 `KeepCurrentContext` 门控。
- `selected_` = **句内**（B），恒有，不受开关控制。
- 两者**顺序拼接**进同一个 trigram 状态：句间词在前，句内词在后。
  关掉 A 后，状态里就只剩句内词（句首时为空 → `nullState`）。

### A. 句间上下文 — `KeepCurrentContext`

「上一句上屏了什么」会进入本句的解码状态。由 addon 在上屏时写入 `contextWords_`：

| 触发点 | 代码 | 动作 |
|---|---|---|
| **上屏提交（正常路径）** | `pinyin.cpp:244-245` `initPredict` | `if (keepCurrentContext) appendContextWordsWithPinyin(selectedWordsWithPinyin)` — 把刚上屏的词加入句间上下文（主入口） |
| 预测中 | `pinyin.cpp:274-275` `updatePredict` | `setContextWordsWithPinyin(predictWords_)` — 把预测词设为上下文 |
| 云拼音提交 | `pinyin.cpp:2584-2585` `cloudPinyinSelected` | `appendContextWordsWithPinyin(words)`（云拼音默认关，不走） |
| 清场 | `pinyin.cpp:1214,1863,2226,2334` | `clearContextWords()` |

`appendContextWordsWithPinyin`（`pinyincontext.cpp:1086`）只保留**最近 2 个词**
（`needed = maxOrder() - 1 = 2`，见 §5）。

**`KeepCurrentContext=False` 时**：所有 append 都被 `if` 跳过，`contextWords_`
恒为空 → `state()` 里 ① 那段循环不执行 → **句间上下文彻底消失**，
`state()` 退化为「只有句内词」（句首即 `nullState`）。

> 这是「同拼音候选漂移」的主因，也是 omarime 默认关掉它的原因（§8）。

### B. 句内上下文 — `selected_`（恒开，无开关）

「本句里你已经选定的词」。它**不经过** `KeepCurrentContext`，
`state()` 里 ② 那段循环无条件执行。

- 作用：长句里你选对了前面的词，后面的候选就被正确引导
  （"我在__" 比裸猜 "__" 准得多）。
- **没有开关，也无法关**——这是句子级解码的固有行为，关掉等于把长句
  拆成一串无关联的单字猜解，体验会变差。
- 与 A 的区别：A 跨「上屏边界」（上一句 → 本句），B 只在本句内部。
  你要的"句内开、句间关"，正好是"保留 B、关掉 A"。

### C. 用户历史 — `UserModelWeight`

不是"上下文状态"，而是**打分时叠加的一层**（§3 的 `userScore`）。
数据来自 `user.history`，权重 `w = UserModelWeight/100`。

- 只影响排序（§3 的 `max`），不增删候选。
- 只加分不降分（§3 要点 1）。
- 学习写入见 §6。

> A 与 C 都会用到"上一个词"，但来源不同：A 的 prev 是**上一句上屏的词**
> （`contextWords_`），C 的 prev 是**state 里最近词**（句内或句间拼出来的）。
> 关掉 A 后，C 的 prev 在句首就是 `<s>`（句边界），不再受上一句影响——
> 这正是"句间关、但个人历史仍在句内生效"。

---

## 5. 上下文窗口：为什么是"最近 2 个词"

- 基础 LM 是 **trigram**（`KENLM_MAX_ORDER = 3`，
  `libime/core/CMakeLists.txt:14`），`LanguageModel::maxOrder()` 返回 3。
- 上下文缓存长度 `needed = maxOrder() - 1 = 2`
  （`pinyincontext.cpp:1057,1090`）——只留**最近 2 个词**喂给三阶模型。
- 用户历史是 **bigram**，只用最近 1 个前词（§3）。

所以「句间」实际只带**上一句最后 2 个词**进来，窗口很窄，
但足以让"今天天气**不错**"影响下一句开头——这也是它容易被感知为"玄学漂移"的原因。

---

## 6. 学习与持久化：上下文是怎么"记下来"的

| 动作 | 代码 | 说明 |
|---|---|---|
| 上屏时学习 | `pinyin.cpp:440` → `PinyinContext::learn()`（`pinyincontext.cpp:1009`） | 提交时**同时**学词 + 学历史 bigram |
| 学词（→ user.dict） | `learn()` 内 `d->learnWord()` | 把整句新词写进用户词典，决定*哪些词会出现* |
| 学 bigram（→ user.history） | `HistoryBigram::addWithContext`（`historybigram.cpp:828`） | 「前词→本词」共现 +1，决定*怎么排序* |
| 跨句边界学习 | `maybeAppendToLatestSentence`（`historybigram.cpp:456`） | bigram 学习的 `prev` 取自句间词（`contextWordsWithPinyin`），可跨上屏 |
| 落盘 | `UserLanguageModel::save`（`userlanguagemodel.cpp:87`） | 持久化到 `user.history` |

> `learn()` 在提交时做**两件独立的事**：
> 1. `learnWord()` 学词 → 写 `user.dict`（哪些词作为候选出现）；
> 2. `addWithContext` 学历史 → 写 `user.history`（这些词怎么排序）。
> 两者是独立学习线，分别对应 §1 的两个用户文件。
>
> 注意 bigram 学习的 `prev` 来自**句间词**（`contextWordsWithPinyin`）。所以关掉 A
> （`KeepCurrentContext=False`）后，句首的 `prev` 变成 `<s>`，跨上屏的 bigram
> 学习也随之停止——与 §4-C 打分侧的结论一致：句间彻底断开，句内/个人历史保留。

---

## 7. 热生效：为什么改配置不用重启 fcitx5

文件：`im/pinyin/pinyin.h:429-432`

```cpp
void setConfig(const RawConfig &config) override {
    config_.load(config, true);
    safeSaveAsIni(config_, "conf/pinyin.conf");
    populateConfig();   // ← 重新把所有配置应用到 ime
}
```

- DBus `SetConfig`（`fcitx://config/addon/pinyin`）→ `PinyinEngine::setConfig()`
  → `populateConfig()`，其中 omarime patch 调用
  `ime_->model()->setHistoryWeight(*config_.userModelWeight / 100.0f)`
  （`engine/patches/pinyin-usermodelweight.patch`）。
- `KeepCurrentContext` 在使用点**内联读取**（`pinyin.cpp:244,274,2584` 的
  `*config_.keepCurrentContext`），所以改完下一次上屏/输入即生效。
- 两者都**无需重启** fcitx5。omarime 的 `bin/omarime-config` 与设置面板
  走的就是这条 DBus 热路径（原子写 + `SetConfig`）。

---

## 8. omarime 的默认值与理由

| 旋钮 | pinyin.conf 键 | 范围 | 上游默认 | **omarime 默认** | 热生效 | 作用 |
|---|---|---|---|---|---|---|
| 句间上下文 | `KeepCurrentContext` | bool | `True` | **`False`** | 是 | 上一句是否引导本句候选 |
| 句内上下文 | —（无键） | — | 恒开 | 恒开 | — | 本句已选词引导后续（设计如此） |
| 用户历史强度 | `UserModelWeight` | 0–100 | `20` | 用户自定（本机 `100`） | 是 | 个人历史在排序里的插值权重 w |

**为什么句间默认关：**
- 句间上下文窗口只有上一句最后 2 个词（§5），却能让"同一串拼音"因
  前一句不同而候选不同——这正是"玄学漂移"的体感来源。
- 关掉后：**同一串拼音，无论前面上过什么屏，候选都稳定一致**；
  而长句内"越打越准"（B）和"越用越懂你"（C）**完全保留**。
- 想找回句间引导：设置面板「跨句上下文」toggle 打开即可（可逆、可发现）。

**为什么句内恒开：** 它是句子级解码的固有能力，没有独立开关；关掉会损害
长句准确度，不属于"可选项"。

**用户历史强度（本机 100）：** `w=1.0` 时 `最终分 = max(基础分, 用户分)`，
个人历史有完全覆盖权。这是"最强个人化"档，且因 `max` 语义**不会把基础 LM
排对的词排错**，只把"你常用的词"顶上来。

> `Prediction`（上屏后预测下一个词）是**另一个独立功能**，不属于以上三个
> 上下文入口，本文不展开。本机为 `Prediction=False`。

---

## 9. 具体例子

设 E6 基础 LM 与用户历史都已就位。

**A 句间（可关）：**
```
上屏：  今天天气不错        → 分词 [今天, 天气, 不错]
                             → contextWords_ = [天气, 不错]   （最后 2 词）
再输：  women
  KeepCurrentContext=True  → state 从 [天气, 不错] 出发
                             → 候选排序受"…不错 women"上下文影响
  KeepCurrentContext=False → contextWords_ 空 → state=nullState
                             → 候选只由基础 LM 决定，与"今天天气不错"无关
```
同一串 `women`，前者候选随上一句变，后者恒定。这就是漂移开关。

**B 句内（恒开）：**
```
输入：  wo zai shurufa
  选定 "我" 之后，selected_ = [我]
  → 后面 "zai shurufa" 的候选由 "我…" 引导（"我在…" 比裸猜准）
  这与上一句无关，纯本句内部，恒开。
```

**C 用户历史（强度可调）：**
```
你历史上常打 "打开 电脑"，user.history 里 bigram(打开→电脑) 频次高
再输 "dian"（前词=打开）：
  w=100 → 最终分 = max(基础分, 用户分)，"电脑" 被用户分顶到更前
  w=0   → 用户分不参与，"电脑" 只按基础 LM 排
  且无论如何，基础 LM 认为更好的词不会被压下去（max 语义）。
```

---

## 10. 怎么调（操作速查）

| 想做什么 | 操作 |
|---|---|
| 关/开 句间上下文 | 设置面板「跨句上下文」toggle；或 `omarime-config set context.inter false`；或直接改 `pinyin.conf` 的 `KeepCurrentContext` |
| 调 用户历史强度 | 设置面板 / `pinyin.conf` 的 `UserModelWeight`（0–100） |
| 让"个人化"更强 | 提高 `UserModelWeight`（只加分不降分，可放心调高） |
| 让"同拼音更稳定" | 关句间（`KeepCurrentContext=False`）——最大杠杆 |
| 回滚 omarime 全部改动 | `install.sh --undo`（含 `pinyin.conf` 的 backup-first 恢复） |

> 所有改动均走 DBus 热生效（§7），**无需重启 fcitx5**。
> 安装器默认写入 `KeepCurrentContext=False`（`install.sh` 的
> `prepare_fcitx_config`，backup-first、幂等、`--undo` 可恢复）。

---

## 11. 代码索引（便于回溯）

| 主题 | 文件:行 |
|---|---|
| 束搜索节点打分 | `libime/core/decoder.cpp:211-229` |
| LM 插值（基础+用户） | `libime/core/userlanguagemodel.cpp:122-139` |
| 对数空间插值 `sum_log_prob` | `libime/core/userlanguagemodel.cpp:118-120` |
| 用户历史 bigram 平滑 | `libime/core/historybigram.cpp:660-686` |
| 上下文状态拼接 | `libime/pinyin/pinyincontext.cpp:581-602`（`state`） |
| 句间窗口长度（=2） | `libime/pinyin/pinyincontext.cpp:1057,1090` |
| 句间写入（addon） | `im/pinyin/pinyin.cpp:244-245, 274-275, 2584-2585` |
| 上屏学习 | `im/pinyin/pinyin.cpp:440` → `pinyincontext.cpp:1009`（`learn`） |
| 跨句边界学习 | `libime/core/historybigram.cpp:456`（`maybeAppendToLatestSentence`） |
| 热生效入口 | `im/pinyin/pinyin.h:429-432`（`setConfig`→`populateConfig`） |
| UserModelWeight patch | `engine/patches/pinyin-usermodelweight.patch` |
| trigram 阶数定义 | `libime/core/CMakeLists.txt:14`（`KENLM_MAX_ORDER=3`） |
| 默认用户权重 0.2 | `libime/core/constants.h:18` |
