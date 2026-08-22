#include <libime/core/userlanguagemodel.h>
#include <iostream>
#include <fstream>
#include <sstream>

int main() {
    // Load the user's actual history
    libime::UserLanguageModel model("/usr/lib/libime/zh_CN.lm");
    std::ifstream in("/home/eipi10/.local/share/fcitx5/pinyin/user.history");
    model.load(in);
    
    std::cout << "weight after load: " << model.historyWeight() << "\n";
    
    // Set weight and save
    model.setHistoryWeight(0.5f);
    std::ostringstream out;
    model.save(out);
    
    // Load from the saved stream and check weight
    libime::UserLanguageModel model2("/usr/lib/libime/zh_CN.lm");
    std::istringstream in2(out.str());
    model2.load(in2);
    
    std::cout << "weight after save+reload: " << model2.historyWeight() << "\n";
    return 0;
}
