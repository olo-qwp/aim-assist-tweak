ARCHS = arm64
TARGET := iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AimAssist

AimAssist_FILES = Tweak.xm \
    AimAssistManager.mm \
    NativeOverlay.mm \
    ESPManager.mm \
    ScreenScanner.mm \
    EnemyMemoryReader.mm

AimAssist_FRAMEWORKS = UIKit CoreGraphics QuartzCore CoreImage CoreVideo ImageIO
AimAssist_CFLAGS   = -fobjc-arc -Wno-deprecated-declarations
AimAssist_CCFLAGS  = -std=c++17
# 强制 MSInitialize 进导出表（dyld3 的 dlsym 只看 export trie，不看 symtab）
AimAssist_LDFLAGS  = -lobjc -Wl,-exported_symbol,_MSInitialize

include $(THEOS_MAKE_PATH)/tweak.mk