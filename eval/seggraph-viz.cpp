// seggraph-viz — 把 SegmentGraph (拼音切分DAG) 画出来
// 用法: seggraph-viz <sc.dict不需要> <lm不需要>
//       直接运行, 内置4个案例; 也接受自定义: seggraph-viz -- <拼音> <inner|corr>
// 输出: 每个案例的 ASCII DAG + 全部切法路径 + Graphviz DOT (/tmp/seg_<n>.dot)
// 编译: g++ -O2 -std=c++20 $(pkg-config --cflags Fcitx5Utils) -I/usr/include/LibIME \
//         -o seggraph-viz seggraph-viz.cpp -lIMEPinyin -lIMECore $(pkg-config --libs Fcitx5Utils)
#include <libime/pinyin/pinyinencoder.h>
#include <libime/pinyin/pinyincorrectionprofile.h>

#include <iostream>
#include <vector>

using namespace libime;

static void draw(const std::string &title, const std::string &py,
                 PinyinFuzzyFlags flags, const PinyinCorrectionProfile *prof,
                 int dotIdx) {
    std::cout << "\n═══════════════ " << title << "  输入=\"" << py << "\" ═══════════════\n";

    SegmentGraph g = prof ? PinyinEncoder::parseUserPinyin(py, prof, flags)
                          : PinyinEncoder::parseUserPinyin(py, flags);

    // ---- 位置轴 + 字母行 ----
    std::cout << "位置:";
    for (size_t i = 0; i <= g.size(); ++i) printf("%*zu", 3, i);
    std::cout << "\n字母:" << std::string(4, ' ');
    for (size_t i = 0; i < g.size(); ++i) printf("%c   ", py[i]);
    std::cout << "\n\n边集 (每条边=一个音节, 从位置i搭到j):\n";

    // ---- 枚举边 ----
    struct Edge {
        size_t from, to;
        char label[16];
    };
    std::vector<Edge> edges;
    for (size_t i = 0; i <= g.size(); ++i) {
        auto rng = g.nodes(i);
        if (rng.begin() == rng.end()) continue;
        for (auto &nx : (&*rng.begin())->nexts()) {
            Edge e{i, nx.index(), {}};
            auto sv = g.segment(i, nx.index());
            size_t n = std::min(sv.size(), sizeof(e.label) - 1);
            memcpy(e.label, sv.data(), n);
            e.label[n] = 0;
            edges.push_back(e);
        }
    }
    for (auto &e : edges) {
        printf("   [%zu→%-2zu] %*s'%s'\n", e.from, e.to,
               (int)(e.from * 6 + 2), "", e.label);
    }

    // ---- 全部切法路径 ----
    std::cout << "\n完整路径 (从0铺到" << g.size() << "的所有切法):\n";
    int cnt = 0, total = 0;
    g.dfs([&](const SegmentGraphBase &, const std::vector<size_t> &path) {
        ++total;
        if (++cnt <= 12) {
            std::cout << "   ";
            size_t prev = 0;
            for (size_t idx : path) {
                std::cout << "'" << g.segment(prev, idx) << "' ";
                prev = idx;
            }
            std::cout << "\n";
        }
        return true;
    });
    if (total == 0) std::cout << "   (无 —— 这个串按当前规则切不通!)\n";
    else if (total > 12) std::cout << "   ... 共" << total << "条\n";
    else std::cout << "   共" << total << "条\n";

    // ---- Graphviz DOT ----
    std::string fn = "/tmp/seg_" + std::to_string(dotIdx) + ".dot";
    FILE *f = fopen(fn.c_str(), "w");
    if (f) {
        fprintf(f, "digraph G {\n rankdir=LR;\n node [shape=circle];\n");
        for (size_t i = 0; i <= g.size(); ++i) {
            auto rng = g.nodes(i);
            if (rng.begin() != rng.end())
                fprintf(f, " %zu [label=\"%zu\"];\n", i, i);
        }
        for (auto &e : edges)
            fprintf(f, " %zu -> %zu [label=\"%s\"];\n", e.from, e.to, e.label);
        fprintf(f, "}\n");
        fclose(f);
        std::cout << "   [DOT已写入 " << fn
                  << ": dot -Tpng " << fn << " -o seg.png 可渲染]\n";
    }
}

int main() {
    int k = 0;
    // 案例1: 经典歧义 xian
    draw("案例1 经典单音节歧义 (Inner开)", "xian",
         PinyinFuzzyFlags{PinyinFuzzyFlag::Inner}, nullptr, ++k);
    // 案例2: 双音节全交叉 fangan
    draw("案例2 两字词交叉歧义 (Inner开)", "fangan",
         PinyinFuzzyFlags{PinyinFuzzyFlag::Inner}, nullptr, ++k);
    // 案例3: 整句长度 (多交叉)
    draw("案例3 整句 \"tajintian\" (Inner开)", "tajintian",
         PinyinFuzzyFlags{PinyinFuzzyFlag::Inner}, nullptr, ++k);
    // 案例4: 打错字母 + QWERTY邻键纠错
    {
        PinyinCorrectionProfile prof(BuiltinPinyinCorrectionProfile::Qwerty);
        std::cout << "\n(对照: 同样的错拼, 不开纠错)\n";
        draw("案例4a 错拼 dw 无纠错", "dw",
             PinyinFuzzyFlags{PinyinFuzzyFlag::None}, nullptr, ++k);
        draw("案例4b 错拼 dw + QWERTY邻键纠错 (想打 de)", "dw",
             PinyinFuzzyFlags{PinyinFuzzyFlag::Correction}, &prof, ++k);
    }
    return 0;
}
