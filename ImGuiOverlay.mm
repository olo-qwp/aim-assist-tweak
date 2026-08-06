#import "ImGuiOverlay.h"
#import "AimAssistManager.h"
#import "imgui.h"
#import "imgui_impl_metal.h"
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

// ═══════════════════════════════════════════════════════════════════
//  单窗口：渲染 + 触摸统一处理
//  - 全屏，负责绘制 FOV 圈 + ImGui 面板
//  - hitTest 智能拦截：面板内触摸 → 自己处理，面板外 → 穿透到游戏
//  - sendEvent 可靠拦截所有触摸事件转发给 ImGui
// ═══════════════════════════════════════════════════════════════════
@interface ImGuiOverlayWindow : UIWindow
@property (nonatomic, assign) CGRect panelRect;  // 由 ImGuiOverlay 每帧更新
@end
@implementation ImGuiOverlayWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    // 仅面板内触摸由本窗口拦截
    if (CGRectContainsPoint(_panelRect, point)) {
        return self;
    }
    return nil;  // 面板外 → 穿透到游戏
}

// ═══════════════════════════════════════════════════════════════════
//  sendEvent: 是 iOS 触摸事件传递的可靠入口
//  UIApplication 将事件发送到最前窗口的 sendEvent:
//  比 touchesBegan: 更可靠，因为窗口没有子视图时 touches 可能不被调用
// ═══════════════════════════════════════════════════════════════════
- (void)sendEvent:(UIEvent *)event {
    if (event.type == UIEventTypeTouches) {
        // 检查触摸点是否在面板内
        UITouch *anyTouch = [event.allTouches anyObject];
        if (anyTouch) {
            CGPoint loc = [anyTouch locationInView:self];
            if (CGRectContainsPoint(_panelRect, loc)) {
                // 面板内触摸 → 转发给 ImGui，不调用 super（阻止事件传递到游戏）
                [self feedImGuiTouches:event.allTouches];
                return;
            }
        }
    }
    // 面板外触摸 → 调用 super 让事件传递到游戏窗口
    [super sendEvent:event];
}

- (void)feedImGuiTouches:(NSSet<UITouch *> *)touches {
    ImGuiContext *ctx = ImGui::GetCurrentContext();
    if (!ctx) return;
    ImGuiIO &io = ImGui::GetIO();
    for (UITouch *touch in touches) {
        CGPoint loc = [touch locationInView:self];
        io.AddMousePosEvent(loc.x, loc.y);
        if (touch.phase == UITouchPhaseBegan) {
            io.AddMouseButtonEvent(0, true);
        } else if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) {
            io.AddMouseButtonEvent(0, false);
        }
    }
}
@end

// ═══════════════════════════════════════════════════════════════════
//  ImGui 浮窗控制器
// ═══════════════════════════════════════════════════════════════════
@interface ImGuiOverlay () <MTKViewDelegate>

@property (nonatomic, assign) BOOL initialized;

@end

@implementation ImGuiOverlay {
    id<MTLDevice>           _device;
    id<MTLCommandQueue>     _commandQueue;
    MTKView                *_mtkView;
    ImGuiOverlayWindow     *_overlayWindow;   // 统一窗口
    CADisplayLink          *_displayLink;
    BOOL                    _showUI;
    float                   _fovRadius;
    float                   _panelPosX;
    float                   _panelPosY;
    float                   _panelWidth;
    float                   _panelHeight;
    float                   _animTime;
}

+ (instancetype)sharedOverlay {
    static ImGuiOverlay *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ImGuiOverlay alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _showUI      = YES;
        _initialized = NO;
        _fovRadius   = 150.0f;
        _animTime    = 0.0f;
        _panelPosX   = 0;
        _panelPosY   = 0;
        _panelWidth  = 0;
        _panelHeight = 0;
    }
    return self;
}

- (void)setupMetalAndImGui {
    if (_initialized) return;

    @try {
        // ── Metal 设备 ──
        _device = MTLCreateSystemDefaultDevice();
        if (!_device) {
            NSLog(@"[AimAssist] Metal device creation failed, aborting overlay init");
            return;
        }
        _commandQueue = [_device newCommandQueue];

        CGRect screenBounds = [UIScreen mainScreen].bounds;

        // ── 创建 MTKView（全屏渲染，禁用触摸以免干扰窗口触摸处理） ──
        _mtkView = [[MTKView alloc] initWithFrame:screenBounds device:_device];
        _mtkView.delegate       = self;
        _mtkView.clearColor     = MTLClearColorMake(0, 0, 0, 0);
        _mtkView.backgroundColor = [UIColor clearColor];
        _mtkView.opaque         = NO;
        _mtkView.userInteractionEnabled = NO;
        _mtkView.enableSetNeedsDisplay = NO;
        _mtkView.paused = NO;
        _mtkView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                     UIViewAutoresizingFlexibleHeight;

        // ── 创建统一窗口（全屏，处理渲染 + 触摸） ──
        _overlayWindow = [[ImGuiOverlayWindow alloc] initWithFrame:screenBounds];
        _overlayWindow.windowLevel       = UIWindowLevelAlert + 100;
        _overlayWindow.backgroundColor   = [UIColor clearColor];
        _overlayWindow.opaque            = NO;
        _overlayWindow.panelRect         = CGRectZero;
        _overlayWindow.hidden            = NO;

        // ── 将 MTKView 添加到窗口 ──
        // 注意：不设置 rootViewController，避免 view controller 对 MTKView 做额外布局裁剪
        // 直接将 MTKView 作为 subview 添加到窗口，确保它始终全屏
        [_overlayWindow addSubview:_mtkView];

        // ── ImGui 初始化 ──
        IMGUI_CHECKVERSION();
        ImGui::CreateContext();
        ImGuiIO &io = ImGui::GetIO();
        io.DisplaySize = ImVec2(screenBounds.size.width, screenBounds.size.height);
        io.IniFilename = NULL;

        // ── 自定义样式 ──
        ImGui::StyleColorsDark();
        ImGuiStyle &style = ImGui::GetStyle();
        style.ScaleAllSizes(2.8f);
        style.WindowRounding  = 16.0f;
        style.FrameRounding   = 8.0f;
        style.GrabRounding    = 8.0f;
        style.GrabMinSize     = 20.0f;
        style.Alpha           = 0.85f;
        style.WindowBorderSize = 1.5f;
        style.FrameBorderSize  = 0.8f;
        style.ItemSpacing     = ImVec2(12, 10);
        style.ItemInnerSpacing = ImVec2(10, 6);
        style.WindowPadding   = ImVec2(16, 14);
        style.FramePadding    = ImVec2(10, 8);

        ImFontConfig fontConfig;
        fontConfig.SizePixels = 28.0f;
        io.Fonts->AddFontDefault(&fontConfig);

        ImGui_ImplMetal_Init(_device);

        _initialized = YES;

        // ── 渲染循环 ──
        _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(renderLoop:)];
        [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    } @catch (NSException *exception) {
        NSLog(@"[AimAssist] Exception during setup: %@ - %@", exception.name, exception.reason);
        _initialized = NO;
    }
}

- (void)renderLoop:(CADisplayLink *)link {
    if (!_initialized || !_mtkView) return;
    _animTime += link.duration;
    [_mtkView draw];
}

#pragma mark - MTKViewDelegate

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    // 当 drawable 尺寸变化时，更新 ImGui 显示尺寸
    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = ImVec2(view.bounds.size.width, view.bounds.size.height);
}

- (void)drawInMTKView:(MTKView *)view {
    if (!_initialized || !_showUI) return;

    CGSize viewSize = view.bounds.size;
    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = ImVec2(viewSize.width, viewSize.height);

    _fovRadius = [[AimAssistManager sharedManager] fovRadius];

    MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
    if (!rpd) return;

    ImGui_ImplMetal_NewFrame(rpd);
    ImGui::NewFrame();

    // ── 绘制 FOV 圈 ──
    [self drawFovCircle];

    // ── 绘制控制面板 ──
    [self drawUI];

    // ── 更新窗口的 panelRect（供 hitTest 精确判断） ──
    _overlayWindow.panelRect = CGRectMake(_panelPosX, _panelPosY,
                                          _panelWidth, _panelHeight);

    ImGui::Render();

    @try {
        id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
        id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:rpd];
        [encoder pushDebugGroup:@"ImGui"];
        ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), commandBuffer, encoder);
        [encoder popDebugGroup];
        [encoder endEncoding];
        [commandBuffer presentDrawable:view.currentDrawable];
        [commandBuffer commit];
    } @catch (NSException *exception) {
        // 忽略渲染异常
    }
}

#pragma mark - FOV 圈绘制

- (void)drawFovCircle {
    AimAssistManager *mgr = [AimAssistManager sharedManager];
    if (!mgr.fovEnabled || !mgr.enabled) return;

    ImGuiIO &io = ImGui::GetIO();
    ImDrawList *drawList = ImGui::GetBackgroundDrawList();

    ImVec2 center = ImVec2(io.DisplaySize.x * 0.5f, io.DisplaySize.y * 0.5f);
    float radius = _fovRadius;

    float pulse = sinf(_animTime * 2.0f) * 0.15f + 0.85f;

    // 外圈
    int outerAlpha = (int)(55 * pulse);
    drawList->AddCircle(center, radius, IM_COL32(0, 200, 255, outerAlpha), 72, 2.5f);

    // 中圈
    drawList->AddCircle(center, radius * 0.6f, IM_COL32(0, 200, 255, 25), 48, 1.2f);

    // 内圈
    drawList->AddCircle(center, radius * 0.3f, IM_COL32(255, 100, 100, 35), 36, 1.0f);

    // 头击模式额外显示红色锁定圈
    if (mgr.headshotMode) {
        drawList->AddCircle(center, mgr.headshotSnapRadius,
                           IM_COL32(255, 50, 50, (int)(80 * pulse)), 24, 2.0f);
        drawList->AddText(ImVec2(center.x - 30, center.y - mgr.headshotSnapRadius - 22),
                         IM_COL32(255, 80, 80, 150), "HEADSHOT");
    }

    // 十字准星
    float crossLen = 18.0f;
    float crossGap = 5.0f;
    ImU32 crossColor = IM_COL32(0, 255, 255, (int)(120 * pulse));
    drawList->AddLine(ImVec2(center.x - crossLen - crossGap, center.y),
                      ImVec2(center.x - crossGap, center.y), crossColor, 2.0f);
    drawList->AddLine(ImVec2(center.x + crossGap, center.y),
                      ImVec2(center.x + crossLen + crossGap, center.y), crossColor, 2.0f);
    drawList->AddLine(ImVec2(center.x, center.y - crossLen - crossGap),
                      ImVec2(center.x, center.y - crossGap), crossColor, 2.0f);
    drawList->AddLine(ImVec2(center.x, center.y + crossGap),
                      ImVec2(center.x, center.y + crossLen + crossGap), crossColor, 2.0f);
    drawList->AddCircleFilled(center, 3.0f, IM_COL32(0, 255, 255, 160));

    // 四角方向标记
    float tickLen = 8.0f;
    ImU32 tickColor = IM_COL32(0, 200, 255, 40);
    drawList->AddLine(ImVec2(center.x, center.y - radius),
                      ImVec2(center.x, center.y - radius + tickLen), tickColor, 1.5f);
    drawList->AddLine(ImVec2(center.x, center.y + radius),
                      ImVec2(center.x, center.y + radius - tickLen), tickColor, 1.5f);
    drawList->AddLine(ImVec2(center.x - radius, center.y),
                      ImVec2(center.x - radius + tickLen, center.y), tickColor, 1.5f);
    drawList->AddLine(ImVec2(center.x + radius, center.y),
                      ImVec2(center.x + radius - tickLen, center.y), tickColor, 1.5f);

    if (mgr.snapToCenter) {
        char buf[64];
        const char *mode = mgr.headshotMode ? "HS" : "SNAP";
        snprintf(buf, sizeof(buf), "%s %.0f%%", mode, mgr.centerPullStrength * 100.0f);
        drawList->AddText(ImVec2(center.x - 40, center.y + radius + 12),
                          IM_COL32(0, 255, 255, 60), buf);
    }
}

#pragma mark - 控制面板

- (void)drawUI {
    AimAssistManager *mgr = [AimAssistManager sharedManager];

    CGSize screen = [UIScreen mainScreen].bounds.size;
    float panelW = fminf(560, screen.width - 20);
    float panelH = 680;

    // 初始位置：屏幕右侧，允许用户自由拖拽到全屏任意位置
    ImVec2 winPos = ImVec2(screen.width - panelW - 10, 40);
    ImVec2 winSize = ImVec2(panelW, panelH);

    ImGui::SetNextWindowPos(winPos, ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowSize(winSize, ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowBgAlpha(0.80f);

    // 允许自由拖拽移动
    ImGui::Begin("AimAssist", &_showUI,
                 ImGuiWindowFlags_NoResize |
                 ImGuiWindowFlags_AlwaysAutoResize);

    // ── 记录面板位置（用于窗口 hitTest 判断） ──
    ImVec2 pos = ImGui::GetWindowPos();
    ImVec2 size = ImGui::GetWindowSize();
    _panelPosX = pos.x;
    _panelPosY = pos.y;
    _panelWidth = size.x;
    _panelHeight = size.y;

    // ── 标题栏（可拖拽） ──
    ImGui::TextColored(ImVec4(0.0f, 0.8f, 1.0f, 1.0f), "AIM ASSIST");
    ImGui::SameLine();
    ImGui::TextDisabled("v2.3");
    ImGui::Separator();
    ImGui::Spacing();

    // ── 1. 主开关 ──
    BOOL enabled = mgr.enabled;
    ImGui::PushStyleColor(ImGuiCol_FrameBg, ImVec4(0.2f, 0.2f, 0.2f, 0.6f));
    if (ImGui::Checkbox("Enable Aim Assist", &enabled)) {
        mgr.enabled = enabled;
        [mgr saveSettings];
    }
    ImGui::PopStyleColor();
    ImGui::Spacing();

    // ── 2. 强度滑块 ──
    ImGui::Text("Smooth Strength");
    float strength = mgr.strength * 100.0f;
    if (ImGui::SliderFloat("##Strength", &strength, 0.0f, 100.0f, "%.0f%%", ImGuiSliderFlags_None)) {
        mgr.strength = strength / 100.0f;
        [mgr saveSettings];
    }
    ImGui::Spacing();

    // ── 3. FOV 设置 ──
    ImGui::Separator();
    ImGui::TextColored(ImVec4(0.0f, 0.8f, 1.0f, 0.9f), "FOV SETTINGS");
    ImGui::Spacing();

    BOOL fovEn = mgr.fovEnabled;
    if (ImGui::Checkbox("Show FOV Circle", &fovEn)) {
        mgr.fovEnabled = fovEn;
        [mgr saveSettings];
    }

    float fovR = _fovRadius;
    ImGui::Text("FOV Radius");
    if (ImGui::SliderFloat("##FOV Radius", &fovR, 40.0f, 400.0f, "%.0f px")) {
        _fovRadius = fovR;
        mgr.fovRadius = fovR;
        [mgr saveSettings];
    }
    ImGui::Spacing();

    // ── 4. 磁吸吸附 ──
    ImGui::Separator();
    ImGui::TextColored(ImVec4(0.0f, 0.8f, 1.0f, 0.9f), "SNAP TO CENTER");
    ImGui::Spacing();

    BOOL snap = mgr.snapToCenter;
    if (ImGui::Checkbox("Snap to Center", &snap)) {
        mgr.snapToCenter = snap;
        [mgr saveSettings];
    }
    ImGui::SameLine();
    ImGui::TextDisabled("(magnetic pull)");

    float pullStr = mgr.centerPullStrength * 100.0f;
    ImGui::Text("Pull Strength");
    if (ImGui::SliderFloat("##PullStr", &pullStr, 0.0f, 100.0f, "%.0f%%", ImGuiSliderFlags_None)) {
        mgr.centerPullStrength = pullStr / 100.0f;
        [mgr saveSettings];
    }
    ImGui::Spacing();

    // ── 5. 头击模式 ──
    ImGui::Separator();
    ImGui::TextColored(ImVec4(1.0f, 0.3f, 0.3f, 0.9f), "HEADSHOT MODE");
    ImGui::Spacing();

    BOOL hsMode = mgr.headshotMode;
    ImGui::PushStyleColor(ImGuiCol_FrameBg, hsMode ? ImVec4(0.4f, 0.1f, 0.1f, 0.6f) : ImVec4(0.2f, 0.2f, 0.2f, 0.6f));
    if (ImGui::Checkbox("Headshot Mode", &hsMode)) {
        mgr.headshotMode = hsMode;
        [mgr saveSettings];
    }
    ImGui::PopStyleColor();
    ImGui::SameLine();
    ImGui::TextDisabled("(snap to head)");

    float snapRadius = mgr.headshotSnapRadius;
    ImGui::Text("Snap Zone");
    if (ImGui::SliderFloat("##SnapZone", &snapRadius, 10.0f, 100.0f, "%.0f px")) {
        mgr.headshotSnapRadius = snapRadius;
        [mgr saveSettings];
    }

    if (hsMode) {
        ImGui::TextColored(ImVec4(1.0f, 0.6f, 0.0f, 1.0f), "!! HEADSHOT ACTIVE !!");
        ImGui::TextColored(ImVec4(0.8f, 0.8f, 0.8f, 0.8f), "Auto-tightens FOV & boosts pull");
    }
    ImGui::Spacing();

    // ── 6. 状态信息 ──
    ImGui::Separator();
    ImGui::Spacing();
    const char *statusText = mgr.enabled ? "ACTIVE" : "INACTIVE";
    ImVec4 statusColor = mgr.enabled
        ? (mgr.headshotMode ? ImVec4(1.0f, 0.3f, 0.0f, 1.0f) : ImVec4(0.0f, 0.9f, 0.4f, 1.0f))
        : ImVec4(0.9f, 0.2f, 0.2f, 1.0f);
    ImGui::TextColored(statusColor, "Status: %s", statusText);

    ImGui::Text("Smoothing:  %.1f%%", mgr.smoothingFactor * 100.0f);
    ImGui::Text("FOV:        %.0f px", _fovRadius);
    if (mgr.snapToCenter) {
        ImGui::Text("Snap Pull:  %.0f%%", mgr.centerPullStrength * 100.0f);
    } else {
        ImGui::TextDisabled("Snap Pull:  OFF");
    }
    if (mgr.headshotMode) {
        ImGui::TextColored(ImVec4(1.0f, 0.3f, 0.0f, 1.0f), "Headshot:    ON (zone %.0fpx)", mgr.headshotSnapRadius);
    }

    // ── 提示 ──
    ImGui::Spacing();
    ImGui::Separator();
    ImGui::Spacing();
    ImGui::TextDisabled("Drag title bar to move anywhere on screen");
    ImGui::TextDisabled("Touch outside panel = passes through to game");

    ImGui::End();
}

#pragma mark - Public

- (void)show {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setupMetalAndImGui];
        if (!_initialized) return;
        self->_overlayWindow.hidden = NO;
        self->_showUI = YES;
    });
}

- (void)hide {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_showUI = NO;
        self->_overlayWindow.hidden = YES;
    });
}

- (BOOL)isVisible {
    return !_overlayWindow.hidden;
}

@end