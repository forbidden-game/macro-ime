// SPDX-License-Identifier: MIT
// Event-driven fcitx5 → macro-ime state bridge.

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <memory>
#include <string>
#include <vector>

#include <fcitx-utils/handlertable.h>
#include <fcitx/addonfactory.h>
#include <fcitx/addoninstance.h>
#include <fcitx/addonmanager.h>
#include <fcitx/event.h>
#include <fcitx/inputcontext.h>
#include <fcitx/instance.h>

namespace fcitx {

class MacroImeState final : public AddonInstance {
public:
    explicit MacroImeState(Instance *instance) : instance_(instance) {
        if (const char *runtime = std::getenv("XDG_RUNTIME_DIR");
            runtime && *runtime) {
            statePath_ = std::filesystem::path(runtime) / "macro-ime" / "state";
            std::error_code error;
            std::filesystem::create_directories(statePath_.parent_path(), error);
        }

        watch(EventType::InputContextInputMethodActivated);
        watch(EventType::InputContextInputMethodDeactivated);
        watch(EventType::InputContextSwitchInputMethod);
        watch(EventType::InputContextFocusIn);

        publish(instance_->mostRecentInputContext());
    }

    ~MacroImeState() override { publishState(0, true); }

private:
    void watch(EventType type) {
        handlers_.push_back(instance_->watchEvent(
            type, EventWatcherPhase::Default, [this, type](Event &event) {
                auto &contextEvent = static_cast<InputContextEvent &>(event);
                auto *context = contextEvent.inputContext();
                // Per-program mode follows focus. Ignore state changes from a
                // background context so the bar represents the active app.
                if (!context || (!context->hasFocus() &&
                                 instance_->lastFocusedInputContext() != context)) {
                    return;
                }

                // Notification events carry the authoritative transition.
                // During Deactivated, querying Instance::inputMethod may still
                // yield the method being left until the rest of the switch
                // pipeline completes.
                if (type == EventType::InputContextInputMethodActivated) {
                    auto &notification =
                        static_cast<InputMethodNotificationEvent &>(event);
                    publishState(notification.name() == "pinyin" ? 2 : 1);
                } else if (type ==
                               EventType::InputContextInputMethodDeactivated) {
                    auto &notification =
                        static_cast<InputMethodNotificationEvent &>(event);
                    if (notification.name() == "pinyin") {
                        publishState(1);
                    } else {
                        publish(context);
                    }
                } else {
                    publish(context);
                }
            }));
    }

    void publish(InputContext *context) {
        if (!context) {
            publishState(0);
            return;
        }
        // Macro IME's active input method is pinyin; keyboard-* is fcitx5's
        // inactive/English state. Keep the bridge product-specific and exact.
        publishState(instance_->inputMethod(context) == "pinyin" ? 2 : 1);
    }

    void publishState(int state, bool force = false) {
        if (statePath_.empty() || (!force && state == lastState_)) {
            return;
        }
        std::ofstream output(statePath_, std::ios::trunc);
        if (!output) {
            return;
        }
        output << state << '\n';
        output.close();
        if (output) {
            lastState_ = state;
        }
    }

    Instance *instance_;
    std::filesystem::path statePath_;
    int lastState_ = -1;
    std::vector<std::unique_ptr<HandlerTableEntry<EventHandler>>> handlers_;
};

class MacroImeStateFactory final : public AddonFactory {
public:
    AddonInstance *create(AddonManager *manager) override {
        return new MacroImeState(manager->instance());
    }
};

} // namespace fcitx

FCITX_ADDON_FACTORY_V2_BACKWARDS(macro_ime_state, fcitx::MacroImeStateFactory)
