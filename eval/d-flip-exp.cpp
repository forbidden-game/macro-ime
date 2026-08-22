// d-flip-exp — 验证: 输入 'd' 的首选为什么有时是"的"有时是"第"
// 三组实验:
//   1) 干净用户模型 → 'd' 的首选 (静态 LM 基线)
//   2) 模拟"最近常打 第一/第二/第三"(直接喂 history) → 'd' 排序变化
//   3) 真实闭环: 输入 di → 选"第" → learn() → 下次 'd' 的排序
// 编译: g++ -O2 -std=c++17 -o d-flip-exp d-flip-exp.cpp $(pkg-config --cflags --libs LibIME)
#include <libime/pinyin/pinyinime.h>
#include <libime/pinyin/pinyincontext.h>
#include <libime/pinyin/pinyindictionary.h>
#include <libime/core/userlanguagemodel.h>

#include <iostream>
#include <memory>

static void showTop(libime::PinyinContext &ctx, const std::string &py, int n) {
    ctx.clear();
    ctx.type(py);
    std::cout << "  输入 '" << py << "' 前 " << n << " 个候选:\n";
    int i = 0;
    for (auto &c : ctx.candidates()) {
        std::cout << "   #" << i + 1 << "  " << c.toString()
                  << "   (score=" << c.score() << ")\n";
        if (++i >= n) break;
    }
}

int main(int argc, char **argv) {
    if (argc < 3) {
        std::cerr << "usage: d-flip-exp <sc.dict> <lm.bin>\n";
        return 1;
    }
    libime::PinyinIME ime(
        std::make_unique<libime::PinyinDictionary>(),
        std::make_unique<libime::UserLanguageModel>(argv[2]));
    ime.dict()->load(libime::PinyinDictionary::SystemDict, argv[1],
                     libime::PinyinDictFormat::Binary);
    libime::PinyinContext ctx(&ime);
    ctx.setMaxSentenceLength(50);

    // ---------- 1) 干净基线 ----------
    std::cout << "== 1) 干净用户模型 (静态 E6 LM 决定) ==\n";
    showTop(ctx, "d", 5);

    // ---------- 2) 模拟最近常打 第X ----------
    std::cout << "\n== 2) 模拟用户最近高频输入 第一/第二/第三 ==\n";
    auto &h = ime.model()->history();
    for (int r = 0; r < 50; ++r) {
        h.add({"第一"});
        h.add({"第二"});
        h.add({"第三"});
    }
    showTop(ctx, "d", 5);

    // ---------- 3) 真实闭环: 选字+learn ----------
    std::cout << "\n== 3) 真实闭环: 打 di 选 '第' 上屏 5 次 ==\n";
    for (int r = 0; r < 5; ++r) {
        ctx.clear();
        ctx.type("di");
        int idx = -1, i = 0;
        for (auto &c : ctx.candidates()) {
            if (c.toString() == "第") { idx = i; break; }
            ++i;
        }
        if (idx < 0) { std::cout << "  [第" << r + 1 << "轮] '第'不在候选\n"; break; }
        ctx.select(idx);
        ctx.learn();
    }
    showTop(ctx, "d", 5);

    // ---------- 4) 忘词回落 ----------
    std::cout << "\n== 4) forget('第') 之后 ==\n";
    h.forget("第");
    showTop(ctx, "d", 5);
    return 0;
}
