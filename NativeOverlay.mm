#import "NativeOverlay.h"
#import "AimAssistManager.h"
#import <QuartzCore/QuartzCore.h>

// ============================================================================
//  全屏浮窗窗口 - 用于显示FOV圈和控制面板
//  - 必须关联 UIWindowScene (iOS 13+) 否则会被限制在 320x480
//  - hitTest 只拦截面板区域内的触摸，其余全部穿透
// ============================================================================
@interface OverlayWindow : UIWindow
@property (nonatomic, weak) UIView *panelView;
@end

@implementation OverlayWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    // 只在面板区域内响应触摸，其余全部穿透到游戏
    if (self.panelView && !self.panelView.hidden && self.panelView.alpha > 0.0) {
        // 将 point 从 window 坐标转换到 panelView 坐标
        CGPoint panelPoint = [self.panelView convertPoint:point fromView:self];
        if (CGRectContainsPoint(self.panelView.bounds, panelPoint)) {
            // 面板内：让 UIKit 找到具体的子控件（开关、滑块等）
            UIView *hit = [super hitTest:point withEvent:event];
            if (hit && hit != self) {
                return hit;
            }
        }
    }
    // 面板外：返回 nil，触摸穿透到游戏窗口
    return nil;
}

@end

// ============================================================================
//  可拖拽控制面板
// ============================================================================
@interface DraggablePanel : UIView
@end

@implementation DraggablePanel {
    CGPoint _dragStartCenter;
    CGPoint _dragStartTouch;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                              action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];

        self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.88];
        self.layer.cornerRadius = 16;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.7;
        self.layer.shadowRadius = 16;
        self.layer.shadowOffset = CGSizeMake(0, 6);
        self.clipsToBounds = NO;
    }
    return self;
}

- (void)handlePan:(UIPanGestureRecognizer *)g {
    CGPoint loc = [g locationInView:self.superview];
    switch (g.state) {
        case UIGestureRecognizerStateBegan:
            _dragStartCenter = self.center;
            _dragStartTouch = loc;
            break;
        case UIGestureRecognizerStateChanged: {
            CGFloat dx = loc.x - _dragStartTouch.x;
            CGFloat dy = loc.y - _dragStartTouch.y;
            CGPoint newCenter = CGPointMake(_dragStartCenter.x + dx, _dragStartCenter.y + dy);

            // 限制不超出屏幕边界
            CGSize screen = self.superview.bounds.size;
            CGFloat halfW = self.bounds.size.width  * 0.5;
            CGFloat halfH = self.bounds.size.height * 0.5;
            newCenter.x = MAX(halfW, MIN(screen.width  - halfW, newCenter.x));
            newCenter.y = MAX(halfH, MIN(screen.height - halfH, newCenter.y));

            self.center = newCenter;
            break;
        }
        default:
            break;
    }
}

@end

// ============================================================================
//  FOV 圆圈绘制层 - 添加到游戏主窗口上
//  用一个独立的全透明 UIView(userInteractionEnabled=NO) 绘制 FOV
// ============================================================================
@interface FOVCircleView : UIView
@property (nonatomic, strong) CAShapeLayer *circleLayer;
@end

@implementation FOVCircleView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];

        _circleLayer = [CAShapeLayer layer];
        _circleLayer.fillColor = [UIColor clearColor].CGColor;
        _circleLayer.strokeColor = [UIColor colorWithRed:1.0 green:0.4 blue:0.1 alpha:0.85].CGColor;
        _circleLayer.lineWidth = 2.5;
        _circleLayer.lineCap = kCALineCapRound;
        [self.layer addSublayer:_circleLayer];

        // 内圈微光
        _circleLayer.shadowColor = [UIColor colorWithRed:1.0 green:0.3 blue:0.0 alpha:0.4].CGColor;
        _circleLayer.shadowRadius = 12;
        _circleLayer.shadowOpacity = 1.0;
        _circleLayer.shadowOffset = CGSizeZero;
    }
    return self;
}

- (void)updateFOVWithRadius:(CGFloat)radius show:(BOOL)show {
    CGSize size = self.bounds.size;
    CGFloat cx = size.width * 0.5;
    CGFloat cy = size.height * 0.5;

    if (show && radius > 0) {
        UIBezierPath *path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(cx, cy)
                                                            radius:radius
                                                        startAngle:0
                                                          endAngle:2 * M_PI
                                                         clockwise:YES];
        _circleLayer.path = path.CGPath;
        _circleLayer.hidden = NO;
    } else {
        _circleLayer.hidden = YES;
    }
}

@end

// ============================================================================
//  NativeOverlay 主实现
// ============================================================================
@implementation NativeOverlay {
    OverlayWindow *_overlayWindow;   // 控制面板窗口
    DraggablePanel *_panelView;      // 控制面板本体
    FOVCircleView *_fovView;        // FOV 绘制视图（添加到游戏主窗口）

    // 控件
    UISwitch *_enableSwitch;
    UISlider *_strengthSlider;
    UILabel *_strengthLabel;

    UISwitch *_fovSwitch;
    UISlider *_fovRadiusSlider;
    UILabel *_fovRadiusLabel;

    UISwitch *_snapSwitch;
    UISlider *_snapStrengthSlider;
    UILabel *_snapStrengthLabel;

    UISwitch *_headshotSwitch;
    UISlider *_headshotRadiusSlider;
    UILabel *_headshotRadiusLabel;
}

+ (instancetype)sharedOverlay {
    static NativeOverlay *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[NativeOverlay alloc] init];
    });
    return instance;
}

// ──────────────────────────────────────────────────────────────────────────
//  初始化：创建 FOV 视图 + 控制面板窗口
// ──────────────────────────────────────────────────────────────────────────
- (instancetype)init {
    self = [super init];
    if (self) {
        [self setupFOVView];
        [self setupPanelWindow];
        [self setupPanel];
        [self syncUI];
    }
    return self;
}

// ──────────────────────────────────────────────────────────────────────────
//  创建 FOV 视图，添加到游戏主窗口
// ──────────────────────────────────────────────────────────────────────────
- (void)setupFOVView {
    // 获取应用主窗口
    UIWindow *keyWindow = nil;
    if (@available(iOS 13.0, *)) {
        NSSet<UIScene *> *scenes = [UIApplication sharedApplication].connectedScenes;
        for (UIScene *scene in scenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                // 找到 foreground 状态的 scene
                if (ws.activationState == UISceneActivationStateForegroundActive) {
                    for (UIWindow *w in ws.windows) {
                        if (w.isKeyWindow) {
                            keyWindow = w;
                            break;
                        }
                    }
                    if (keyWindow) break;
                }
            }
        }
    }
    if (!keyWindow) {
        keyWindow = [UIApplication sharedApplication].keyWindow;
    }
    // 兜底：取第一个 window
    if (!keyWindow) {
        keyWindow = [UIApplication sharedApplication].windows.firstObject;
    }

    if (keyWindow) {
        _fovView = [[FOVCircleView alloc] initWithFrame:keyWindow.bounds];
        _fovView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [keyWindow addSubview:_fovView];
    }
}

// ──────────────────────────────────────────────────────────────────────────
//  创建控制面板窗口（关联 UIWindowScene）
// ──────────────────────────────────────────────────────────────────────────
- (void)setupPanelWindow {
    UIWindowScene *scene = nil;
    if (@available(iOS 13.0, *)) {
        NSSet<UIScene *> *scenes = [UIApplication sharedApplication].connectedScenes;
        for (UIScene *s in scenes) {
            if ([s isKindOfClass:[UIWindowScene class]] &&
                s.activationState == UISceneActivationStateForegroundActive) {
                scene = (UIWindowScene *)s;
                break;
            }
        }
        // 兜底：任意 window scene
        if (!scene) {
            for (UIScene *s in scenes) {
                if ([s isKindOfClass:[UIWindowScene class]]) {
                    scene = (UIWindowScene *)s;
                    break;
                }
            }
        }
    }

    CGRect screenBounds = [UIScreen mainScreen].bounds;

    if (@available(iOS 13.0, *)) {
        _overlayWindow = [[OverlayWindow alloc] initWithWindowScene:scene];
        _overlayWindow.frame = screenBounds;
    } else {
        _overlayWindow = [[OverlayWindow alloc] initWithFrame:screenBounds];
    }

    _overlayWindow.windowLevel = UIWindowLevelStatusBar + 200;
    _overlayWindow.backgroundColor = [UIColor clearColor];
    _overlayWindow.opaque = NO;
    _overlayWindow.hidden = NO;
    _overlayWindow.rootViewController = [[UIViewController alloc] init];
}

// ──────────────────────────────────────────────────────────────────────────
//  创建控制面板 UI
// ──────────────────────────────────────────────────────────────────────────
- (void)setupPanel {
    CGFloat panelWidth = 280;
    CGFloat panelHeight = 380;
    CGFloat x = 20;
    CGFloat y = 80;

    _panelView = [[DraggablePanel alloc] initWithFrame:CGRectMake(x, y, panelWidth, panelHeight)];
    _overlayWindow.panelView = _panelView;
    [_overlayWindow addSubview:_panelView];

    CGFloat cy = 14;
    CGFloat pad = 8;
    CGFloat lh = 20;
    CGFloat ch = 30;
    CGFloat sw = 52;

    // ── 标题 ──
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, cy, panelWidth - 32, 28)];
    title.text = @"AimAssist";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:19];
    [_panelView addSubview:title];
    cy += 28 + pad;

    // ── 开启自瞄 ──
    _enableSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(panelWidth - sw - 8, cy, sw, ch)];
    _enableSwitch.on = [AimAssistManager sharedManager].enabled;
    [_enableSwitch addTarget:self action:@selector(enableChanged:) forControlEvents:UIControlEventValueChanged];
    [_panelView addSubview:_enableSwitch];

    UILabel *l0 = [[UILabel alloc] initWithFrame:CGRectMake(16, cy, 140, ch)];
    l0.text = @"开启自瞄";
    l0.textColor = [UIColor whiteColor];
    l0.font = [UIFont systemFontOfSize:15];
    [_panelView addSubview:l0];
    cy += ch + pad;

    // ── 辅助强度 ──
    _strengthLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, cy, panelWidth - 32, lh)];
    _strengthLabel.textColor = [UIColor whiteColor];
    _strengthLabel.font = [UIFont systemFontOfSize:13];
    [_panelView addSubview:_strengthLabel];
    cy += lh;

    _strengthSlider = [[UISlider alloc] initWithFrame:CGRectMake(16, cy, panelWidth - 32, ch)];
    _strengthSlider.minimumValue = 0;
    _strengthSlider.maximumValue = 1.0;
    _strengthSlider.value = [AimAssistManager sharedManager].strength;
    [_strengthSlider addTarget:self action:@selector(strengthChanged:) forControlEvents:UIControlEventValueChanged];
    [_panelView addSubview:_strengthSlider];
    cy += ch + pad + 4;

    // ── 分隔线 ──
    UIView *sep1 = [[UIView alloc] initWithFrame:CGRectMake(12, cy, panelWidth - 24, 1)];
    sep1.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.1];
    [_panelView addSubview:sep1];
    cy += 8;

    // ── 显示FOV圈 ──
    _fovSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(panelWidth - sw - 8, cy, sw, ch)];
    _fovSwitch.on = [AimAssistManager sharedManager].fovEnabled;
    [_fovSwitch addTarget:self action:@selector(fovChanged:) forControlEvents:UIControlEventValueChanged];
    [_panelView addSubview:_fovSwitch];

    UILabel *l1 = [[UILabel alloc] initWithFrame:CGRectMake(16, cy, 140, ch)];
    l1.text = @"显示FOV圈";
    l1.textColor = [UIColor whiteColor];
    l1.font = [UIFont systemFontOfSize:15];
    [_panelView addSubview:l1];
    cy += ch + pad;

    // ── FOV半径 ──
    _fovRadiusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, cy, panelWidth - 32, lh)];
    _fovRadiusLabel.textColor = [UIColor whiteColor];
    _fovRadiusLabel.font = [UIFont systemFontOfSize:13];
    [_panelView addSubview:_fovRadiusLabel];
    cy += lh;

    _fovRadiusSlider = [[UISlider alloc] initWithFrame:CGRectMake(16, cy, panelWidth - 32, ch)];
    _fovRadiusSlider.minimumValue = 40;
    _fovRadiusSlider.maximumValue = 400;
    _fovRadiusSlider.value = [AimAssistManager sharedManager].fovRadius;
    [_fovRadiusSlider addTarget:self action:@selector(fovRadiusChanged:) forControlEvents:UIControlEventValueChanged];
    [_panelView addSubview:_fovRadiusSlider];
    cy += ch + pad + 4;

    // ── 分隔线 ──
    UIView *sep2 = [[UIView alloc] initWithFrame:CGRectMake(12, cy, panelWidth - 24, 1)];
    sep2.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.1];
    [_panelView addSubview:sep2];
    cy += 8;

    // ── 磁吸中心 ──
    _snapSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(panelWidth - sw - 8, cy, sw, ch)];
    _snapSwitch.on = [AimAssistManager sharedManager].snapToCenter;
    [_snapSwitch addTarget:self action:@selector(snapChanged:) forControlEvents:UIControlEventValueChanged];
    [_panelView addSubview:_snapSwitch];

    UILabel *l2 = [[UILabel alloc] initWithFrame:CGRectMake(16, cy, 140, ch)];
    l2.text = @"磁吸中心";
    l2.textColor = [UIColor whiteColor];
    l2.font = [UIFont systemFontOfSize:15];
    [_panelView addSubview:l2];
    cy += ch + pad;

    // ── 磁吸强度 ──
    _snapStrengthLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, cy, panelWidth - 32, lh)];
    _snapStrengthLabel.textColor = [UIColor whiteColor];
    _snapStrengthLabel.font = [UIFont systemFontOfSize:13];
    [_panelView addSubview:_snapStrengthLabel];
    cy += lh;

    _snapStrengthSlider = [[UISlider alloc] initWithFrame:CGRectMake(16, cy, panelWidth - 32, ch)];
    _snapStrengthSlider.minimumValue = 0;
    _snapStrengthSlider.maximumValue = 1.0;
    _snapStrengthSlider.value = [AimAssistManager sharedManager].centerPullStrength;
    [_snapStrengthSlider addTarget:self action:@selector(snapStrengthChanged:) forControlEvents:UIControlEventValueChanged];
    [_panelView addSubview:_snapStrengthSlider];
    cy += ch + pad + 4;

    // ── 分隔线 ──
    UIView *sep3 = [[UIView alloc] initWithFrame:CGRectMake(12, cy, panelWidth - 24, 1)];
    sep3.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.1];
    [_panelView addSubview:sep3];
    cy += 8;

    // ── 头击模式 ──
    _headshotSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(panelWidth - sw - 8, cy, sw, ch)];
    _headshotSwitch.on = [AimAssistManager sharedManager].headshotMode;
    [_headshotSwitch addTarget:self action:@selector(headshotChanged:) forControlEvents:UIControlEventValueChanged];
    [_panelView addSubview:_headshotSwitch];

    UILabel *l3 = [[UILabel alloc] initWithFrame:CGRectMake(16, cy, 140, ch)];
    l3.text = @"头击模式";
    l3.textColor = [UIColor whiteColor];
    l3.font = [UIFont systemFontOfSize:15];
    [_panelView addSubview:l3];
    cy += ch + pad;

    // ── 锁定半径 ──
    _headshotRadiusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, cy, panelWidth - 32, lh)];
    _headshotRadiusLabel.textColor = [UIColor whiteColor];
    _headshotRadiusLabel.font = [UIFont systemFontOfSize:13];
    [_panelView addSubview:_headshotRadiusLabel];
    cy += lh;

    _headshotRadiusSlider = [[UISlider alloc] initWithFrame:CGRectMake(16, cy, panelWidth - 32, ch)];
    _headshotRadiusSlider.minimumValue = 10;
    _headshotRadiusSlider.maximumValue = 100;
    _headshotRadiusSlider.value = [AimAssistManager sharedManager].headshotSnapRadius;
    [_headshotRadiusSlider addTarget:self action:@selector(headshotRadiusChanged:) forControlEvents:UIControlEventValueChanged];
    [_panelView addSubview:_headshotRadiusSlider];
    cy += ch + pad;
}

// ──────────────────────────────────────────────────────────────────────────
//  同步 UI 显示
// ──────────────────────────────────────────────────────────────────────────
- (void)syncUI {
    AimAssistManager *mgr = [AimAssistManager sharedManager];

    _strengthSlider.value = mgr.strength;
    [self updateStrengthLabel];

    _fovRadiusSlider.value = mgr.fovRadius;
    [self updateFovRadiusLabel];

    _snapStrengthSlider.value = mgr.centerPullStrength;
    [self updateSnapStrengthLabel];

    _headshotRadiusSlider.value = mgr.headshotSnapRadius;
    [self updateHeadshotRadiusLabel];
}

// ──────────────────────────────────────────────────────────────────────────
//  UI 标签更新
// ──────────────────────────────────────────────────────────────────────────
- (void)updateStrengthLabel {
    _strengthLabel.text = [NSString stringWithFormat:@"辅助强度: %d%%", (int)(_strengthSlider.value * 100)];
}

- (void)updateFovRadiusLabel {
    _fovRadiusLabel.text = [NSString stringWithFormat:@"FOV半径: %dpt", (int)_fovRadiusSlider.value];
}

- (void)updateSnapStrengthLabel {
    _snapStrengthLabel.text = [NSString stringWithFormat:@"磁吸强度: %d%%", (int)(_snapStrengthSlider.value * 100)];
}

- (void)updateHeadshotRadiusLabel {
    _headshotRadiusLabel.text = [NSString stringWithFormat:@"锁定半径: %dpt", (int)_headshotRadiusSlider.value];
}

// ──────────────────────────────────────────────────────────────────────────
//  控件事件
// ──────────────────────────────────────────────────────────────────────────
- (void)enableChanged:(UISwitch *)s {
    [AimAssistManager sharedManager].enabled = s.on;
    [[AimAssistManager sharedManager] saveSettings];
}

- (void)strengthChanged:(UISlider *)s {
    [AimAssistManager sharedManager].strength = s.value;
    [[AimAssistManager sharedManager] saveSettings];
    [self updateStrengthLabel];
}

- (void)fovChanged:(UISwitch *)s {
    [AimAssistManager sharedManager].fovEnabled = s.on;
    [[AimAssistManager sharedManager] saveSettings];
    [self updateFOV];
}

- (void)fovRadiusChanged:(UISlider *)s {
    [AimAssistManager sharedManager].fovRadius = s.value;
    [[AimAssistManager sharedManager] saveSettings];
    [self updateFovRadiusLabel];
    [self updateFOV];
}

- (void)snapChanged:(UISwitch *)s {
    [AimAssistManager sharedManager].snapToCenter = s.on;
    [[AimAssistManager sharedManager] saveSettings];
}

- (void)snapStrengthChanged:(UISlider *)s {
    [AimAssistManager sharedManager].centerPullStrength = s.value;
    [[AimAssistManager sharedManager] saveSettings];
    [self updateSnapStrengthLabel];
}

- (void)headshotChanged:(UISwitch *)s {
    [AimAssistManager sharedManager].headshotMode = s.on;
    [[AimAssistManager sharedManager] saveSettings];
}

- (void)headshotRadiusChanged:(UISlider *)s {
    [AimAssistManager sharedManager].headshotSnapRadius = s.value;
    [[AimAssistManager sharedManager] saveSettings];
    [self updateHeadshotRadiusLabel];
}

// ──────────────────────────────────────────────────────────────────────────
//  更新 FOV 圈
// ──────────────────────────────────────────────────────────────────────────
- (void)updateFOV {
    AimAssistManager *mgr = [AimAssistManager sharedManager];
    [_fovView updateFOVWithRadius:mgr.fovRadius show:(mgr.fovEnabled && mgr.fovRadius > 0)];
}

// ──────────────────────────────────────────────────────────────────────────
//  公共接口
// ──────────────────────────────────────────────────────────────────────────
- (void)show {
    _overlayWindow.hidden = NO;
    if (_fovView) {
        // 确保 FOV 视图在正确的窗口上（如果游戏窗口已改变，重新添加）
        // 如果已经有父视图，就不动了
        if (!_fovView.superview) {
            [self setupFOVView];
        }
        // 更新 FOV 视图 frame 以匹配当前屏幕
        _fovView.frame = _fovView.superview.bounds;
    }
    [self updateFOV];
}

- (void)hide {
    _overlayWindow.hidden = YES;
    [_fovView removeFromSuperview];
    _fovView = nil;
}

- (BOOL)isVisible {
    return !_overlayWindow.hidden;
}

@end