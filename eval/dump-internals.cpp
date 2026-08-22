// dump-internals — 把候选词生成的每个中间数据结构真实打印出来
// 输入例子: "xian" (先 / 县 / 西·安 三义歧义)
// 块A: SegmentGraph (拼音切分DAG)
// 块B: Lattice (词典匹配后的"词砖"叠加图)
// 块C: beam解码出的整句候选(路径+分数)
// 块D: HistoryBigram 内部(学习写入了什么)
// 块E: 同一输入, 学习前后冠军变化
// 编译: g++ -O2 -std=c++20 $(pkg-config --cflags Fcitx5Utils) -I/usr/include/LibIME \
//         -o dump-internals dump-internals.cpp -lIMEPinyin -lIMECore $(pkg-config --libs Fcitx5Utils)
#include <libime/pinyin/pinyindecoder.h>
#include <libime/pinyin/pinyindictionary.h>
#include <libime/pinyin/pinyinencoder.h>
#include <libime/core/userlanguagemodel.h>

#include <algorithm>
#include <iostream>
#include <memory>

using namespace libime;

static std::string enc(const char *py) {
    // 与解码侧 PinyinLatticeNode::encodedPinyin() 同源的紧凑编码
    auto v = PinyinEncoder::encodeFullPinyin(py);
    return {v.begin(), v.end()};
}

static void dumpGraph(const SegmentGraph &g) {
    std::cout << "【块A】SegmentGraph —— 拼音切分DAG (位置轴0.." << g.size()
              << ", 每条DFS路径=一种合法切法)\n";
    g.dfs([&](const SegmentGraphBase &, const std::vector<size_t> &path) {
        std::cout << "   切法: ";
        size_t prev = 0;
        for (size_t idx : path) {
            std::cout << "'" << g.segment(prev, idx) << "' ";
            prev = idx;
        }
        std::cout << "\n";
        return true;
    });
}

static void dumpLattice(const Lattice &lat, const SegmentGraph &g) {
    std::cout << "\n【块B】Lattice —— 叠加在图上的\"词砖\" (每块砖=一个词, 从i搭到j)\n";
    for (size_t i = 1; i <= g.size(); ++i) {
        auto rng = g.nodes(i);
        if (rng.begin() == rng.end()) continue; // 该位置无节点
        const SegmentGraphNode *gn = &*rng.begin();
        std::vector<const LatticeNode *> bricks;
        for (const auto &ln : lat.nodes(gn)) bricks.push_back(&ln);
        std::sort(bricks.begin(), bricks.end(), [](auto *a, auto *b) {
            return a->score() > b->score();
        });
        size_t shown = std::min<size_t>(bricks.size(), 12);
        std::cout << "   终点@" << i << " 共" << bricks.size() << "块砖 (按分数显示前"
                  << shown << "):\n";
        for (size_t k = 0; k < shown; ++k) {
            auto *ln = bricks[k];
            std::cout << "     [" << ln->from()->index() << "→" << ln->to()->index()
                      << "] “" << ln->word() << "”  cost=" << ln->cost()
                      << " score=" << ln->score() << "\n";
        }
    }
}

static void dumpCandidates(const Lattice &lat) {
    std::cout << "\n【块C】beam解码结果 —— 铺满全程的最优路径 (top" << lat.sentenceSize()
              << ")\n";
    for (size_t k = 0; k < lat.sentenceSize() && k < 8; ++k) {
        std::cout << "   #" << k + 1 << " 《" << lat.sentence(k).toString()
                  << "》 总分=" << lat.sentence(k).score() << "\n";
    }
}

int main(int argc, char **argv) {
    if (argc < 3) {
        std::cerr << "usage: dump-internals <sc.dict> <lm.bin>\n";
        return 1;
    }
    PinyinDictionary dict;
    dict.load(PinyinDictionary::SystemDict, argv[1], PinyinDictFormat::Binary);
    UserLanguageModel model(argv[2]);
    // 真实引擎(fcitx5-pinyin)也会设置这个: 从 lattice 节点提取拼音编码,
    // 作为查询用户历史的 key —— 没有它, 学习写入的计数查不到
    model.setCodeExtractor([](const libime::WordNode *node) {
        auto *pn = dynamic_cast<const libime::PinyinLatticeNode *>(node);
        return pn ? pn->encodedPinyin() : std::string{};
    });
    PinyinDecoder decoder(&dict, &model);

    // ---------- 块A/B/C: 干净状态下的解剖 ----------
    // Inner=True 对应 pinyin.conf 里开着的分段辅助: 让 xian 也能切成 xi'an
    PinyinFuzzyFlags flags{PinyinFuzzyFlag::Inner};
    SegmentGraph g = PinyinEncoder::parseUserPinyin("xian", flags);
    dumpGraph(g);

    Lattice lat;
    decoder.decode(lat, g, 8, model.nullState());
    if (lat.sentenceSize() == 0) { // 某些版本需 beginState
        Lattice lat2;
        decoder.decode(lat2, g, 5, model.beginState());
        lat = std::move(lat2);
    }
    dumpLattice(lat, g);
    dumpCandidates(lat);

    // ---------- 块D: 用户模型里到底存了什么 ----------
    std::cout << "\n【块D】HistoryBigram —— 你的两张计数控\n";
    auto &h = model.history();
    std::cout << "   学习前: freq(西安)=" << h.unigramFrequency({"西安", enc("xi'an")})
              << "  bigram(西安→大学)="
              << h.bigramFrequency({"西安", enc("xi'an")}, {"大学", enc("da'xue")})
              << "\n";
    for (int r = 0; r < 20; ++r) {
        h.addWithCode({{"西安", enc("xi'an")}, {"大学", enc("da'xue")}});
    }
    std::cout << "   上屏“西安大学”×20 后:\n";
    std::cout << "   freq(西安)=" << h.unigramFrequency({"西安", enc("xi'an")})
              << "  bigram(西安→大学)="
              << h.bigramFrequency({"西安", enc("xi'an")}, {"大学", enc("da'xue")})
              << "  bigram(西安→电大)="
              << h.bigramFrequency({"西安", enc("xi'an")}, {"电大", enc("dian'da")})
              << "\n";

    // ---------- 块E: 同一输入, 冠军换了 ----------
    std::cout << "\n【块E】同一输入 \"xian\", 计数变了 → 排名变了\n";
    Lattice lat3;
    decoder.decode(lat3, g, 8, model.nullState());
    dumpCandidates(lat3);
    return 0;
}
