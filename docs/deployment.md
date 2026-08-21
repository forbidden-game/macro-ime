# 引擎部署记录 — E6 上线 (2026-02-22)

当前生产状态: **fcitx5-pinyin (libime) + omarime-e6.lm.bin**, 用户实测通过。

## 部署步骤 (可复现)

```bash
# 0. 备份原版
sudo cp /usr/lib/libime/zh_CN.lm{,.orig}          # 25MB 官方2008模型
sudo cp /usr/lib/libime/zh_CN.lm.predict{,.orig}

# 1. 换脑
sudo cp omarime-e6.lm.bin /usr/lib/libime/zh_CN.lm

# 2. 重建预测索引 (需要 ARPA 源)
/usr/bin/libime_prediction zh_CN.lm e6.arpa zh_CN.lm.predict.new
sudo cp zh_CN.lm.predict.new /usr/lib/libime/zh_CN.lm.predict

# 3. 接入输入法组 (⚠️ 必须先停服务再改 profile, 见下)
systemctl --user stop omarchy-fcitx5.service
$EDITOR ~/.config/fcitx5/profile     # keyboard-us → pinyin → rime, DefaultIM=pinyin
systemctl --user start omarchy-fcitx5.service
```

## ⚠️ 三个坑

1. **fcitx5 退出时回写 profile**: 运行中改 `~/.config/fcitx5/profile` 会被
   内存态覆盖。必须 停服→改→启。
2. **懒加载**: fcitx5 启动后 RSS 只有 ~45MB 是正常的; 442MB 模型在首次
   打字时才 mmap 进来。
3. **验证手段**: `busctl --user call org.fcitx.Fcitx5 /controller
   org.fcitx.Fcitx.Controller1 CurrentInputMethod` 看实际激活的引擎,
   不要只看配置文件。

## pinyin.conf 配置键速查 (~/.config/fcitx5/conf/pinyin.conf)

`[Fuzzy]` 节(键名来自 im/pinyin/pinyin.h 的 FuzzyConfig):

- 基础辅助(默认 True): `VE_UE` `NG_GN` `LowerCaseMatchLetter` `Inner`
  `InnerShort` `PartialFinal`
- 模糊音对(**默认全 False**): `AN_ANG` `EN_ENG` `IN_ING` `IAN_IANG`
  `UAN_UANG` `C_CH` `S_SH` `Z_ZH` `L_N` `F_H` `L_R` `V_U` `U_OU`
- `Correction`: None/Qwerty — 键盘邻键纠错, 桌面默认 None

### 当前用户决策 (2026-02-22)

- 模糊音对: **全部关闭** (E6 准确率足够, 正确拼音无需模糊, 开了反而添噪)
- `Correction=Qwerty`: **保留** (解决"打错字母从头再来")
- 其余基础辅助: 默认保留
- 切换热键: 维持 Ctrl+Space (用户明确拒绝 Super+Space)

## 回滚

```bash
sudo cp ~/work/omarime-data/backup/zh_CN.lm.orig /usr/lib/libime/zh_CN.lm
sudo cp ~/work/omarime-data/backup/zh_CN.lm.predict.orig /usr/lib/libime/zh_CN.lm.predict
# profile 中把 pinyin 换回/删掉即可 (停服再改)
```

## 后续正式化 (v2)

包文件替换会被系统更新冲掉。正式形态 = 自写 fcitx5 addon 干净加载
omarime.lm + pacman hook 或独立数据包分发。
