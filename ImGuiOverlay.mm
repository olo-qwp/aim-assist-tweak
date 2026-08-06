#import "ImGuiOverlay.h"
#import "AimAssistManager.h"
#import "imgui.h"
#import "imgui_impl_metal.h"
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

// ── 透传窗口：精确触摸热区管理 ──
// 仅当触摸点在 ImGui 面板区域内且 ImGui 需要捕获时拦截
// 否则全部穿透到游戏
@interface ImGuiOverlayWindow : UIWindow {
    CGRect _imguiPanelRect;  // 由 ImGuiOverlay 更新
}
@property (nonatomic, assign) CGRect imguiPanelRect;
@end

@implementation ImGuiOverlayWindow

@synthesize imguiPanelRect = _imguiPanelRect;

/// 获取当前所有 UIWindow（iOS 15+ 兼容方法）
+ (NSArray<UIWindow *> *)allWindows {
    NSMutableArray<UIWindow *> *result = [NSMutableArray array];
    if (@available(iOS 15.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                [result addObjectsFromArray:ws.windows];
            }
        }
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [result addObjectsFromArray:[UIApplication sharedApplication].windows];
#pragma clang diagnostic pop
    }
    return result;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    // ── 第1步：判断触摸点是否在 ImGui 面板矩形内 ──
    BOOL insidePanel = CGRectContainsPoint(_imguiPanelRect, point);

    if (!insidePanel) {
        // ── 完全在面板外 → 直接穿透到游戏 ──
        // 不调用 super hitTest，不返回任何本窗口的 view
        return [self hitTestForwardToGame:point withEvent:event];
    }

    // ── 在面板内 → 检查 ImGui 是否需要捕获 ──
    ImGuiContext *ctx = ImGui::GetCurrentContext();
    if (ctx) {
        ImGuiIO &io = ImGui::GetIO();
        if (io.WantCaptureMouse || io.WantCaptureKeyboard) {
            // ImGui 需要捕获 → 返回正常的 hitTest 结果
            return [super hitTest:point withEvent:event];
        }
    }

    // ── ImGui 不需要捕获 → 穿透到游戏 ──
    return [self hitTestForwardToGame:point withEvent:event];
}

/// 将触摸转发到游戏窗口
- (UIView *)hitTestForwardToGame:(CGPoint)point withEvent:(UIEvent *)event {
    NSArray<UIWindow *> *windows = [self.class allWindows];
    // 从最上层开始遍历，找到本窗口之下的游戏窗口
    for (NSInteger i = windows.count - 1; i >= 0; i--) {
        UIWindow *w = windows[i];
        if (w == self || w.hidden || !w.userInteractionEnabled) continue;
        if (w.windowLevel >= self.windowLevel) continue;
        UIView *gameHit = [w hitTest:point withEvent:event];
        if (gameHit) return gameHit;
    }
    return nil;
}

// ── 触摸事件转发到 ImGui ──
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self feedImGuiTouches:touches];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self feedImGuiTouches:touches];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self feedImGuiTouches:touches];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self feedImGuiTouches:touches];
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

// ── ImGui 浮窗控制器 ──
@interface ImGuiOverlay () <MTKViewDelegate>

@property (nonatomic, assign) BOOL initialized;

@end

@implementation ImGuiOverlay {
    id<MTLDevice>       _device;
    id<MTLCommandQueue> _commandQueue;
    MTKView            *_mtkView;
    ImGuiOverlayWindow  *_window;
    CADisplayLink      *_displayLink;
    BOOL                _showUI;
    float               _fovRadius;           // 当前 FOV 半径（可调）
    float               _panelPosX;           // 面板位置 X
    float               _panelPosY;           // 面板位置 Y
    float               _panelWidth;          // 面板宽度
    float               _panelHeight;         // 面板高度
    float               _animTime;            // 动画时间（FOV圈脉冲）
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

        _mtkView = [[MTKView alloc] initWithFrame:screenBounds device:_device];
        _mtkView.delegate     = self;
        _mtkView.clearColor   = MTLClearColorMake(0, 0, 0, 0);
        _mtkView.backgroundColor = [UIColor clearColor];
        _mtkView.opaque       = NO;
        _mtkView.userInteractionEnabled = YES;
        _mtkView.enableSetNeedsDisplay = NO;
        _mtkView.paused = NO;

        _window = [[ImGuiOverlayWindow alloc] initWithFrame:screenBounds];
        _window.windowLevel       = UIWindowLevelAlert + 100;
        _window.rootViewController = [[UIViewController alloc] init];
        _window.rootViewController.view = _mtkView;
        _window.backgroundColor   = [UIColor clearColor];
        _window.opaque            = NO;
        _window.userInteractionEnabled = YES;
        _window.hidden            = NO;

        // ── ImGui 初始化 ──
        IMGUI_CHECKVERSION();
        ImGui::CreateContext();
        ImGuiIO &io = ImGui::GetIO();
        io.DisplaySize = ImVec2(screenBounds.size.width, screenBounds.size.height);
        io.IniFilename = NULL;

        // ── 自定义样式：超大尺寸 + 半透明暗色 ──
        ImGui::StyleColorsDark();
        ImGuiStyle &style = ImGui::GetStyle();
        style.ScaleAllSizes(2.8f);           // 整体缩放 2.8x
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

        // 超大字体
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

// ── MTKViewDelegate ──
- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}

- (void)drawInMTKView:(MTKView *)view {
    if (!_initialized || !_showUI) return;

    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = ImVec2(view.bounds.size.width, view.bounds.size.height);

    // 更新 FOV 半径
    _fovRadius = [[AimAssistManager sharedManager] fovRadius];

    MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
    if (!rpd) return;

    ImGui_ImplMetal_NewFrame(rpd);
    ImGui::NewFrame();

    // ── 先绘制 FOV 圈（在背景层） ──
    [self drawFovCircle];

    // ── 再绘制控制面板 ──
    [self drawUI];

    // ── 更新窗口的热区矩形（供 hitTest 精确判断） ──
    _window.imguiPanelRect = CGRectMake(_panelPosX, _panelPosY, _panelWidth, _panelHeight);

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
        // 忽略渲染异常，避免崩溃
    }
}

// ── 增强 FOV 圈绘制（带脉冲动画） ──
- (void)drawFovCircle {
    AimAssistManager *mgr = [AimAssistManager sharedManager];
    if (!mgr.fovEnabled || !mgr.enabled) return;

    ImGuiIO &io = ImGui::GetIO();
    ImDrawList *drawList = ImGui::GetBackgroundDrawList();

    ImVec2 center = ImVec2(io.DisplaySize.x * 0.5f, io.DisplaySize.y * 0.5f);
    float radius = _fovRadius;

    // 脉冲动画：呼吸效果
    float pulse = sinf(_animTime * 2.0f) * 0.15f + 0.85f;

    // ── 外圈（脉冲透明度，亮色） ──
    int outerAlpha = (int)(55 * pulse);
    drawList->AddCircle(center, radius,
                        IM_COL32(0, 200, 255, outerAlpha), 72, 2.5f);

    // ── 中圈（辅助对齐） ──
    drawList->AddCircle(center, radius * 0.6f,
                        IM_COL32(0, 200, 255, 25), 48, 1.2f);

    // ── 内圈（小范围精确瞄准区） ──
    drawList->AddCircle(center, radius * 0.3f,
                        IM_COL32(255, 100, 100, 35), 36, 1.0f);

    // ── 中心十字准星（游戏风格） ──
    float crossLen = 18.0f;
    float crossGap = 5.0f;
    ImU32 crossColor = IM_COL32(0, 255, 255, (int)(120 * pulse));

    // 水平线
    drawList->AddLine(ImVec2(center.x - crossLen - crossGap, center.y),
                      ImVec2(center.x - crossGap, center.y), crossColor, 2.0f);
    drawList->AddLine(ImVec2(center.x + crossGap, center.y),
                      ImVec2(center.x + crossLen + crossGap, center.y), crossColor, 2.0f);
    // 垂直线
    drawList->AddLine(ImVec2(center.x, center.y - crossLen - crossGap),
                      ImVec2(center.x, center.y - crossGap), crossColor, 2.0f);
    drawList->AddLine(ImVec2(center.x, center.y + crossGap),
                      ImVec2(center.x, center.y + crossLen + crossGap), crossColor, 2.0f);

    // 圆心点
    drawList->AddCircleFilled(center, 3.0f, IM_COL32(0, 255, 255, 160));

    // ── 四角方向指示标记（辅助快速定位中心） ──
    float tickLen = 8.0f;
    ImU32 tickColor = IM_COL32(0, 200, 255, 40);
    // 上
    drawList->AddLine(ImVec2(center.x, center.y - radius),
                      ImVec2(center.x, center.y - radius + tickLen), tickColor, 1.5f);
    // 下
    drawList->AddLine(ImVec2(center.x, center.y + radius),
                      ImVec2(center.x, center.y + radius - tickLen), tickColor, 1.5f);
    // 左
    drawList->AddLine(ImVec2(center.x - radius, center.y),
                      ImVec2(center.x - radius + tickLen, center.y), tickColor, 1.5f);
    // 右
    drawList->AddLine(ImVec2(center.x + radius, center.y),
                      ImVec2(center.x + radius - tickLen, center.y), tickColor, 1.5f);

    // ── 如果磁吸开启，额外显示提示文字 ──
    if (mgr.snapToCenter) {
        char buf[64];
        snprintf(buf, sizeof(buf), "SNAP %.0f%%", mgr.centerPullStrength * 100.0f);
        drawList->AddText(ImVec2(center.x - 40, center.y + radius + 12),
                          IM_COL32(0, 255, 255, 60), buf);
    }
}

// ── 超大控制面板（带新控件） ──
- (void)drawUI {
    AimAssistManager *mgr = [AimAssistManager sharedManager];

    CGSize screen = [UIScreen mainScreen].bounds.size;
    float panelW = fminf(520, screen.width - 20);
    float panelH = 620;

    // 窗口位置：右侧居中
    ImVec2 winPos = ImVec2(screen.width - panelW - 10, 40);
    ImVec2 winSize = ImVec2(panelW, panelH);

    ImGui::SetNextWindowPos(winPos, ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowSize(winSize, ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowBgAlpha(0.80f);

    ImGui::Begin("AimAssist", &_showUI,
                 ImGuiWindowFlags_NoTitleBar |
                 ImGuiWindowFlags_NoResize |
                 ImGuiWindowFlags_AlwaysAutoResize);

    // ── 记录面板位置（用于精确触摸热区） ──
    ImVec2 pos = ImGui::GetWindowPos();
    ImVec2 size = ImGui::GetWindowSize();
    _panelPosX = pos.x;
    _panelPosY = pos.y;
    _panelWidth = size.x;
    _panelHeight = size.y;

    // ── 标题栏 ──
    ImGui::TextColored(ImVec4(0.0f, 0.8f, 1.0f, 1.0f), "AIM ASSIST");
    ImGui::SameLine();
    ImGui::TextDisabled("v2.0");
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

    // ── 4. 磁吸吸附设置 ──
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

    // ── 5. 状态信息 ──
    ImGui::Separator();
    ImGui::Spacing();
    const char *statusText = mgr.enabled ? "ACTIVE" : "INACTIVE";
    ImVec4 statusColor = mgr.enabled
        ? ImVec4(0.0f, 0.9f, 0.4f, 1.0f)
        : ImVec4(0.9f, 0.2f, 0.2f, 1.0f);
    ImGui::TextColored(statusColor, "Status: %s", statusText);

    ImGui::Text("Smoothing:  %.1f%%", mgr.smoothingFactor * 100.0f);
    ImGui::Text("FOV:        %.0f px", _fovRadius);
    if (mgr.snapToCenter) {
        ImGui::Text("Snap Pull:  %.0f%%", mgr.centerPullStrength * 100.0f);
    } else {
        ImGui::TextDisabled("Snap Pull:  OFF");
    }

    // ── 触摸热区提示 ──
    ImGui::Spacing();
    ImGui::Separator();
    ImGui::Spacing();
    ImGui::TextDisabled("Touch outside panel = passes through to game");
    ImGui::TextDisabled("Drag panel title to reposition");

    ImGui::End();
}

#pragma mark - Public

- (void)show {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setupMetalAndImGui];
        if (!_initialized) return;
        self->_window.hidden = NO;
        self->_showUI = YES;
    });
}

- (void)hide {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_showUI = NO;
        self->_window.hidden = YES;
    });
}

- (BOOL)isVisible {
    return !_window.hidden;
}

@end