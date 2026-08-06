ARCHS = arm64
TARGET := iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AimAssist

AimAssist_FILES = Tweak.xm \
    AimAssistManager.mm \
    ImGuiOverlay.mm \
    ImGui/imgui.cpp \
    ImGui/imgui_draw.cpp \
    ImGui/imgui_widgets.cpp \
    ImGui/imgui_tables.cpp \
    ImGui/imgui_impl_metal.mm

AimAssist_FRAMEWORKS = UIKit Metal MetalKit CoreGraphics QuartzCore
AimAssist_CFLAGS   = -fobjc-arc -I$(THEOS_PROJECT_DIR)/ImGui
AimAssist_CCFLAGS  = -std=c++17
AimAssist_LDFLAGS  =

include $(THEOS_MAKE_PATH)/tweak.mk