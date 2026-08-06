#import "ImGuiOverlay.h"
#import "AimAssistManager.h"
#import "imgui.h"
#import "imgui_impl_metal.h"
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

// ── 透传窗口：仅在 ImGui 需要输入时拦截触摸，否则穿透到游戏 ──
@interface ImGuiOverlayWindow : UIWindow
@end

@implementation ImGuiOverlayWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (hitView == self || hitView == self.subviews.firstObject) {
        // 确保 ImGui 上下文已初始化，避免空指针崩溃
        ImGuiContext *ctx = ImGui::GetCurrentContext();
        if (ctx && (ImGui::GetIO().WantCaptureMouse || ImGui::GetIO().WantCaptureKeyboard)) {
            return hitView;
        }
        return nil; // 穿透触摸到游戏
    }
    return hitView;
}

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
    if (!ctx) return; // 上下文未初始化，不处理
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

@end

@implementation ImGuiOverlay {
    id<MTLDevice>       _device;
    id<MTLCommandQueue> _commandQueue;
    MTKView            *_mtkView;
    ImGuiOverlayWindow  *_window;
    CADisplayLink      *_displayLink;
    BOOL                _showUI;
    BOOL                _initialized;
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

        ImGui::StyleColorsDark();
        ImGuiStyle &style = ImGui::GetStyle();
        style.ScaleAllSizes(2.0f);
        style.WindowRounding  = 8.0f;
        style.FrameRounding   = 4.0f;
        style.GrabRounding    = 4.0f;
        style.Alpha           = 0.9f;

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
    [_mtkView draw];
}

// ── MTKViewDelegate ──
- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}

- (void)drawInMTKView:(MTKView *)view {
    if (!_initialized || !_showUI) return;

    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = ImVec2(view.bounds.size.width, view.bounds.size.height);

    MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
    if (!rpd) return;

    ImGui_ImplMetal_NewFrame(rpd);
    ImGui::NewFrame();

    [self drawUI];

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

- (void)drawUI {
    AimAssistManager *mgr = [AimAssistManager sharedManager];

    ImGui::SetNextWindowPos(ImVec2(15, 120), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowSize(ImVec2(300, 260), ImGuiCond_FirstUseEver);

    ImGui::Begin("Aim Assist", &_showUI,
                 ImGuiWindowFlags_NoTitleBar |
                 ImGuiWindowFlags_AlwaysAutoResize |
                 ImGuiWindowFlags_NoResize);

    ImGui::TextColored(ImVec4(0.3f, 0.9f, 0.3f, 1.0f), "Aim Assist v1.0");
    ImGui::Separator();
    ImGui::Spacing();

    // 开关
    BOOL enabled = mgr.enabled;
    if (ImGui::Checkbox("Enable", &enabled)) {
        mgr.enabled = enabled;
        [mgr saveSettings];
    }

    ImGui::Spacing();

    // 强度滑块
    float strength = mgr.strength * 100.0f;
    if (ImGui::SliderFloat("Strength", &strength, 0.0f, 100.0f, "%.0f%%")) {
        mgr.strength = strength / 100.0f;
        mgr.smoothingFactor = mgr.strength * 0.8f;
        [mgr saveSettings];
    }

    ImGui::Spacing();
    ImGui::Separator();
    ImGui::Spacing();

    // 状态指示
    const char *statusText = mgr.enabled ? "Active" : "Inactive";
    ImVec4 statusColor = mgr.enabled
        ? ImVec4(0.2f, 0.9f, 0.2f, 1.0f)
        : ImVec4(0.9f, 0.2f, 0.2f, 1.0f);
    ImGui::TextColored(statusColor, "Status: %s", statusText);

    ImGui::Text("Smoothing: %.1f%%", mgr.smoothingFactor * 100.0f);

    ImGui::Spacing();
    ImGui::Separator();
    ImGui::Spacing();

    ImGui::TextDisabled("v1.0.0 | iGameGod");

    ImGui::End();
}

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