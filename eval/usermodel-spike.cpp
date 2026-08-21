// usermodel-spike v2 — 用户自适应双路径验证
// A: 已在词典但排序错误("摆烂"被"白兰"压住) → 选字+learn 能否翻转?
// B: OOV 新词("王小明") → addWord 进 UserDict 后能否成为候选并学会?
#include <libime/pinyin/pinyinime.h>
#include <libime/pinyin/pinyincontext.h>
#include <libime/pinyin/pinyindictionary.h>
#include <libime/core/userlanguagemodel.h>

#include <fstream>
#include <iostream>
#include <memory>

static std::string top1(libime::PinyinContext &ctx, const std::string &py) {
    ctx.clear();
    ctx.type(py);
    auto &c = ctx.candidates();
    return c.empty() ? "<无候选>" : c[0].toString();
}

int main(int argc, char **argv) {
    if (argc < 3) {
        std::cerr << "usage: usermodel-spike2 <sc.dict> <lm.bin>\n";
        return 1;
    }
    libime::PinyinIME ime(
        std::make_unique<libime::PinyinDictionary>(),
        std::make_unique<libime::UserLanguageModel>(argv[2]));
    ime.dict()->load(libime::PinyinDictionary::SystemDict, argv[1],
                     libime::PinyinDictFormat::Binary);
    libime::PinyinContext ctx(&ime);
    ctx.setMaxSentenceLength(50);

    // ---------- 测试 A: 排序翻转 ----------
    std::string pyA = "tajintianyoukaishibailanle";
    std::string wantA = "他今天又开始摆烂了";
    std::cout << "== A. 排序学习 ==\n[基线]   " << top1(ctx, pyA) << "\n";
    for (int r = 1; r <= 3; ++r) {
        ctx.clear();
        ctx.type(pyA);
        int idx = -1, i = 0;
        for (auto &c : ctx.candidates()) {
            if (c.toString() == wantA) { idx = i; break; }
            ++i;
        }
        if (idx < 0) { std::cout << "[第" << r << "轮] 目标不在候选\n"; break; }
        ctx.select(idx);
        ctx.learn();
        std::cout << "[第" << r << "轮] 学习候选#" << idx << "\n";
    }
    std::cout << "[学习后] " << top1(ctx, pyA)
              << (top1(ctx, pyA) == wantA ? "  ✅翻转" : "  ❌未翻转") << "\n";

    // ---------- 测试 B: OOV 新词 ----------
    std::cout << "\n== B. 用户词典新词 ==\n";
    std::string pyB = "wangxiaomingzhuzaibeijing";
    std::cout << "[加词前] " << top1(ctx, pyB) << "\n";
    ime.dict()->addWord(libime::PinyinDictionary::UserDict, "wang'xiao'ming",
                        "王小明");
    ime.model()->setHistoryWeight(1.0f);
    ctx.clear();
    ctx.type(pyB);
    bool found = false;
    int i = 0;
    for (auto &c : ctx.candidates()) {
        if (c.toString().find("王小明") != std::string::npos) { found = true; break; }
        ++i;
    }
    std::cout << "[加词后] 候选含'王小明': " << (found ? "是" : "否");
    if (found) {
        std::cout << "\n[候选预览] ";
        {   ctx.clear(); ctx.type(pyB);
            int k = 0;
            for (auto &c : ctx.candidates()) {
                if (k++ >= 3) break;
                std::cout << c.toString() << " | ";
            }
        }
        // 连选 5 次: 选含"王小明"的最长候选
        for (int r = 0; r < 5; ++r) {
            ctx.clear();
            ctx.type(pyB);
            int idx = -1, best = -1, j = 0;
            for (auto &c : ctx.candidates()) {
                if (c.toString().find("王小明") != std::string::npos) {
                    idx = j;
                    if ((int)c.toString().size() > best) { best = c.toString().size(); }
                }
                ++j;
            }
            if (idx < 0) { std::cout << "[第" << r << "轮]无含王小明候选\n"; break; }
            ctx.select(idx);
            ctx.learn();
        }
        std::string t = top1(ctx, pyB);
        std::cout << "\n[学习后] " << t
                  << (t.find("王小明") != std::string::npos ? "  ✅新词上位" : "  ⚠️仍非首选");
    }
    std::cout << "\n";
    return 0;
}
