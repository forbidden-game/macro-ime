#include <libime/pinyin/pinyindictionary.h>
#include <iostream>
#include <fstream>
int main(int argc, char** argv) {
    libime::PinyinDictionary dict;
    dict.load(libime::PinyinDictionary::SystemDict, argv[1], libime::PinyinDictFormat::Binary);
    std::ofstream out(argv[2]);
    dict.save(libime::PinyinDictionary::SystemDict, out, libime::PinyinDictFormat::Text);
    return 0;
}
