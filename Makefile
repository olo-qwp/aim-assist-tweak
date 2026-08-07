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
    ScreenScanner.mm

AimAssist_FRAMEWORKS = UIKit CoreGraphics QuartzCore CoreImage CoreVideo ImageIO
AimAssist_CFLAGS   = -fobjc-arc -Wno-deprecated-declarations
AimAssist_CCFLAGS  = -std=c++17
AimAssist_LDFLAGS  = -lobjc

include $(THEOS_MAKE_PATH)/tweak.mk