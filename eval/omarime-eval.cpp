// omarime-eval — LM 对比评测工具 (Spike)
// 用法: omarime-eval <sc.dict> <lm.bin> <eval.tsv>
//   eval.tsv 每行: 拼音<TAB>期望句子
// 输出: 每行结果 + 汇总 (句准确率 P@1 / 字准确率)
//
// 编译: g++ -O2 -std=c++17 -o omarime-eval omarime-eval.cpp \
//        $(pkg-config --cflags --libs LibIME)   (装好 libime 后)
#include <libime/pinyin/pinyinime.h>
#include <libime/pinyin/pinyincontext.h>
#include <libime/pinyin/pinyindictionary.h>
#include <libime/core/userlanguagemodel.h>

#include <fstream>
#include <iostream>
#include <memory>
#include <sstream>

int main(int argc, char **argv) {
    if (argc != 4) {
        std::cerr << "usage: " << argv[0] << " <sc.dict> <lm.bin> <eval.tsv>\n";
        return 1;
    }

    libime::PinyinIME ime(
        std::make_unique<libime::PinyinDictionary>(),
        std::make_unique<libime::UserLanguageModel>(argv[2]));
    ime.dict()->load(libime::PinyinDictionary::SystemDict, argv[1],
                     libime::PinyinDictFormat::Binary);

    std::ifstream test(argv[3]);
    if (!test) {
        std::cerr << "cannot open " << argv[3] << "\n";
        return 1;
    }

    size_t total = 0, sent_ok = 0, char_total = 0, char_ok = 0;
    std::string line;
    while (std::getline(test, line)) {
        auto tab = line.find('\t');
        if (tab == std::string::npos) continue;
        std::string pinyin = line.substr(0, tab);
        std::string expect = line.substr(tab + 1);

        libime::PinyinContext ctx(&ime);
        ctx.setMaxSentenceLength(50);
        ctx.type(pinyin);

        std::string got;
        // 首选完整句
        got = ctx.sentence();
        if (got.empty() && !ctx.candidates().empty()) {
            got = ctx.candidates()[0].toString();
        }

        ++total;
        bool ok = (got == expect);
        if (ok) ++sent_ok;
        // 字级: 逐字符比较(简单 LCS 退化为位置比较, 句长不同即全错——
        // Spike 够用; 正式版换编辑距离)
        if (got.size() == expect.size()) {
            for (size_t i = 0; i < got.size(); i += 3) { // UTF-8 中文3字节
                ++char_total;
                if (got.compare(i, 3, expect, i, 3) == 0) ++char_ok;
            }
        } else {
            char_total += expect.size() / 3;
        }

        std::cout << (ok ? "PASS" : "FAIL") << '\t' << pinyin << '\t'
                  << expect << '\t' << got << '\n';
    }

    std::cout << "==== SUMMARY ====\n"
              << "sentences: " << total << "\n"
              << "P@1 (sentence): " << (total ? sent_ok * 100.0 / total : 0) << "%\n"
              << "char acc:       " << (char_total ? char_ok * 100.0 / char_total : 0) << "%\n";
    return 0;
}
