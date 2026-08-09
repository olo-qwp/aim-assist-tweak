#import "NativeOverlay.h"
#import "AimAssistManager.h"
#import "ESPManager.h"
#import "ScreenScanner.h"
#import <QuartzCore/QuartzCore.h>

// ═══════════════════════════════════════════════════════════════════════════
//  ESP 绘制视图 — 覆盖全屏，绘制骨骼/方框/准心/FOV
//  userInteractionEnabled = NO，不拦截触摸
// ═══════════════════════════════════════════════════════════════════════════
@interface ESPDrawView : UIView
@property (nonatomic, strong) CADisplayLink *displayLink;
@end

@implementation ESPDrawView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;

        _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(onDisplayLink:)];
        [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (void)dealloc {
    [_displayLink invalidate];
}

- (void)onDisplayLink:(CADisplayLink *)sender {
    if (self.hidden || self.window == nil) return; // 隐藏时不浪费帧
    [self setNeedsDisplay];
}

// ═══════════════════════════════════════════════════════════════════════════
//  Core Graphics 绘制入口
// ═══════════════════════════════════════════════════════════════════════════
- (void)drawRect:(CGRect)rect {
    [super drawRect:rect];
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    CGSize screen = self.bounds.size;
    CGFloat cx = screen.width * 0.5f;
    CGFloat cy = screen.height * 0.5f;

    ESPManager *esp = [ESPManager sharedManager];
    AimAssistManager *aa = [AimAssistManager sharedManager];

    // ── 1. 绘制 FOV 圈（始终显示，表示自瞄范围） ──
    if (aa.fovEnabled && aa.fovRadius > 0) {
        [self drawFOVCircleAt:CGPointMake(cx, cy) radius:aa.fovRadius context:ctx];
    }

    // ── 2. 绘制准心 ──
    if (esp.showCrosshair) {
        [self drawCrosshairAt:CGPointMake(cx, cy) context:ctx];
    }

    // ── 3. 绘制 ESP 数据 ──
    if (esp.espEnabled) {
        NSArray *players = [esp currentPlayers];
        for (ESPPlayerData *p in players) {
            if (!p.isValid) continue;

            // 骨骼（在方框下面）
            if (esp.showSkeleton && p.hasBones) {
                [self drawSkeleton:p context:ctx];
            }

            // 方框
            if (esp.showBox && !CGRectIsEmpty(p.boxRect)) {
                UIColor *color = p.isEnemy ? [UIColor redColor] : [UIColor greenColor];
                [self drawBox:p.boxRect color:color context:ctx];
            }

            // 血条
            if (esp.showHealth && !CGRectIsEmpty(p.boxRect)) {
                [self drawHealthBar:p.boxRect health:p.health context:ctx];
            }

            // 名字
            if (esp.showName && p.name.length > 0) {
                [self drawName:p.name at:p.screenPos context:ctx];
            }

            // 如果ESP开启且自瞄开启，标记锁定目标（最近敌人头部高亮）
            if (aa.enabled && p.isEnemy && p.hasBones) {
                CGPoint head = p->bonePositions[ESPBoneHead];
                CGFloat hdx = head.x - cx;
                CGFloat hdy = head.y - cy;
                CGFloat hdist = sqrtf(hdx * hdx + hdy * hdy);
                if (hdist < aa.fovRadius) {
                    // 绘制目标指示线（从准心到敌人头部）
                    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:1.0 green:0.8 blue:0.0 alpha:0.3].CGColor);
                    CGContextSetLineWidth(ctx, 1.0);
                    CGFloat dashes[] = {4, 4};
                    CGContextSetLineDash(ctx, 0, dashes, 2);
                    CGContextBeginPath(ctx);
                    CGContextMoveToPoint(ctx, cx, cy);
                    CGContextAddLineToPoint(ctx, head.x, head.y);
                    CGContextStrokePath(ctx);
                    CGContextSetLineDash(ctx, 0, NULL, 0);
                }
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  绘制准心
// ═══════════════════════════════════════════════════════════════════════════
- (void)drawCrosshairAt:(CGPoint)center context:(CGContextRef)ctx {
    CGFloat len = 15.0f;
    CGFloat gap = 5.0f;
    CGFloat w = 2.0f;

    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:0.0 green:1.0 blue:0.3 alpha:0.9].CGColor);
    CGContextSetLineWidth(ctx, w);

    CGContextBeginPath(ctx);
    CGContextMoveToPoint(ctx, center.x, center.y - gap);
    CGContextAddLineToPoint(ctx, center.x, center.y - gap - len);
    CGContextMoveToPoint(ctx, center.x, center.y + gap);
    CGContextAddLineToPoint(ctx, center.x, center.y + gap + len);
    CGContextMoveToPoint(ctx, center.x - gap, center.y);
    CGContextAddLineToPoint(ctx, center.x - gap - len, center.y);
    CGContextMoveToPoint(ctx, center.x + gap, center.y);
    CGContextAddLineToPoint(ctx, center.x + gap + len, center.y);
    CGContextStrokePath(ctx);

    // 中心点
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:1.0 green:0.3 blue:0.0 alpha:0.9].CGColor);
    CGContextFillEllipseInRect(ctx, CGRectMake(center.x - 3, center.y - 3, 6, 6));
}

// ═══════════════════════════════════════════════════════════════════════════
//  绘制 FOV 圈
// ═══════════════════════════════════════════════════════════════════════════
- (void)drawFOVCircleAt:(CGPoint)center radius:(CGFloat)r context:(CGContextRef)ctx {
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:1.0 green:0.5 blue:0.0 alpha:0.6].CGColor);
    CGContextSetLineWidth(ctx, 1.5);
    CGFloat dashes[] = {8, 4};
    CGContextSetLineDash(ctx, 0, dashes, 2);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(center.x - r, center.y - r, r * 2, r * 2));
    CGContextSetLineDash(ctx, 0, NULL, 0);
}

// ═══════════════════════════════════════════════════════════════════════════
//  绘制骨骼
// ═══════════════════════════════════════════════════════════════════════════
- (void)drawSkeleton:(ESPPlayerData *)p context:(CGContextRef)ctx {
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:0.3 green:0.8 blue:1.0 alpha:0.9].CGColor);
    CGContextSetLineWidth(ctx, 2.0);

    for (int i = 0; ; i += 2) {
        int from = ESPBoneConnections[i];
        int to = ESPBoneConnections[i + 1];
        if (from < 0 || to < 0) break;

        CGPoint pf = p->bonePositions[from];
        CGPoint pt = p->bonePositions[to];
        if (pf.x <= 0 && pf.y <= 0) continue;
        if (pt.x <= 0 && pt.y <= 0) continue;

        CGContextBeginPath(ctx);
        CGContextMoveToPoint(ctx, pf.x, pf.y);
        CGContextAddLineToPoint(ctx, pt.x, pt.y);
        CGContextStrokePath(ctx);
    }

    // 头部高亮圆圈
    CGPoint head = p->bonePositions[ESPBoneHead];
    if (head.x > 0 || head.y > 0) {
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:1.0 green:0.3 blue:0.3 alpha:0.9].CGColor);
        CGContextSetLineWidth(ctx, 2.5);
        CGContextStrokeEllipseInRect(ctx, CGRectMake(head.x - 8, head.y - 8, 16, 16));
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  绘制方框
// ═══════════════════════════════════════════════════════════════════════════
- (void)drawBox:(CGRect)rect color:(UIColor *)color context:(CGContextRef)ctx {
    CGContextSetStrokeColorWithColor(ctx, color.CGColor);
    CGContextSetLineWidth(ctx, 2.0);
    CGContextStrokeRect(ctx, rect);
}

// ═══════════════════════════════════════════════════════════════════════════
//  绘制血条
// ═══════════════════════════════════════════════════════════════════════════
- (void)drawHealthBar:(CGRect)box health:(CGFloat)health context:(CGContextRef)ctx {
    CGFloat barW = 4;
    CGFloat barH = box.size.height;
    CGFloat barX = box.origin.x - barW - 2;
    CGFloat barY = box.origin.y;

    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.2 alpha:0.8].CGColor);
    CGContextFillRect(ctx, CGRectMake(barX, barY, barW, barH));

    CGFloat fillH = barH * MAX(0, MIN(1, health));
    UIColor *healthColor = health > 0.6 ? [UIColor greenColor] :
                           health > 0.3 ? [UIColor yellowColor] : [UIColor redColor];
    CGContextSetFillColorWithColor(ctx, healthColor.CGColor);
    CGContextFillRect(ctx, CGRectMake(barX, barY + barH - fillH, barW, fillH));
}

// ═══════════════════════════════════════════════════════════════════════════
//  绘制名字
// ═══════════════════════════════════════════════════════════════════════════
- (void)drawName:(NSString *)name at:(CGPoint)pos context:(CGContextRef)ctx {
    NSDictionary *attrs = @{
        NSFontAttributeName: [UIFont boldSystemFontOfSize:12],
        NSForegroundColorAttributeName: [UIColor whiteColor]
    };
    CGSize size = [name sizeWithAttributes:attrs];
    CGPoint drawPos = CGPointMake(pos.x - size.width * 0.5f, pos.y - 30);
    [name drawAtPoint:drawPos withAttributes:attrs];
}

@end

// ═══════════════════════════════════════════════════════════════════════════
//  全屏浮窗窗口 — 用于控制按钮和触摸穿透
// ═══════════════════════════════════════════════════════════════════════════
@interface OverlayWindow : UIWindow
@property (nonatomic, weak) UIView *controlView;
@end

@implementation OverlayWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.controlView && !self.controlView.hidden && self.controlView.alpha > 0.0) {
        CGPoint cp = [self.controlView convertPoint:point fromView:self];
        if (CGRectContainsPoint(self.controlView.bounds, cp)) {
            UIView *hit = [super hitTest:point withEvent:event];
            if (hit && hit != self) return hit;
        }
    }
    return nil;
}

@end

// ═══════════════════════════════════════════════════════════════════════════
//  可拖拽控制面板
// ═══════════════════════════════════════════════════════════════════════════
@interface ControlPanel : UIView
@end

@implementation ControlPanel {
    CGPoint _dragStartCenter;
    CGPoint _dragStartTouch;
    BOOL _minimized;
    CGPoint _savedCenter;
    UIView *_minimizedView;
    UIView *_fullView;
    UILabel *_statusLabel;
    UILabel *_aimStatusLabel;
    NSTimer *_statusTimer;   // 1Hz 刷新数据源显示
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _minimized = NO;
        [self setupFullMode];
        [self setupMinimizedMode];
        [self showFullMode];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                              action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];
    }
    return self;
}

// ── 全屏模式 ──
- (void)setupFullMode {
    _fullView = [[UIView alloc] initWithFrame:self.bounds];
    _fullView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _fullView.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.85];
    _fullView.layer.cornerRadius = 14;
    _fullView.layer.shadowColor = [UIColor blackColor].CGColor;
    _fullView.layer.shadowOpacity = 0.6;
    _fullView.layer.shadowRadius = 12;
    _fullView.layer.shadowOffset = CGSizeMake(0, 4);
    [self addSubview:_fullView];

    CGFloat w = self.bounds.size.width;
    CGFloat cy = 12;

    // 标题行
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(14, cy, w - 50, 26)];
    title.text = @"ESP+Aim Assist";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:15];
    [_fullView addSubview:title];

    // 最小化按钮
    UIButton *minBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    minBtn.frame = CGRectMake(w - 34, 9, 28, 28);
    minBtn.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.6];
    minBtn.layer.cornerRadius = 14;
    minBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [minBtn setTitle:@"─" forState:UIControlStateNormal];
    [minBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [minBtn addTarget:self action:@selector(minimize) forControlEvents:UIControlEventTouchUpInside];
    [_fullView addSubview:minBtn];
    cy += 30;

    // ── 自瞄开关 ──
    UILabel *l1 = [[UILabel alloc] initWithFrame:CGRectMake(14, cy, 80, 26)];
    l1.text = @"自瞄";
    l1.textColor = [UIColor whiteColor];
    l1.font = [UIFont systemFontOfSize:13];
    [_fullView addSubview:l1];

    UISwitch *aimSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(w - 58, cy - 1, 48, 26)];
    aimSwitch.on = [AimAssistManager sharedManager].enabled;
    aimSwitch.transform = CGAffineTransformMakeScale(0.7, 0.7);
    [aimSwitch addTarget:self action:@selector(aimToggled:) forControlEvents:UIControlEventValueChanged];
    [_fullView addSubview:aimSwitch];
    cy += 28;

    // ── ESP 开关 ──
    UILabel *l2 = [[UILabel alloc] initWithFrame:CGRectMake(14, cy, 80, 26)];
    l2.text = @"ESP透视";
    l2.textColor = [UIColor whiteColor];
    l2.font = [UIFont systemFontOfSize:13];
    [_fullView addSubview:l2];

    UISwitch *espSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(w - 58, cy - 1, 48, 26)];
    espSwitch.on = [ESPManager sharedManager].espEnabled;
    espSwitch.transform = CGAffineTransformMakeScale(0.7, 0.7);
    [espSwitch addTarget:self action:@selector(espToggled:) forControlEvents:UIControlEventValueChanged];
    [_fullView addSubview:espSwitch];
    cy += 28;

    // ── 骨骼开关 ──
    UILabel *l3 = [[UILabel alloc] initWithFrame:CGRectMake(14, cy, 80, 26)];
    l3.text = @"骨骼";
    l3.textColor = [UIColor whiteColor];
    l3.font = [UIFont systemFontOfSize:13];
    [_fullView addSubview:l3];

    UISwitch *boneSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(w - 58, cy - 1, 48, 26)];
    boneSwitch.on = [ESPManager sharedManager].showSkeleton;
    boneSwitch.transform = CGAffineTransformMakeScale(0.7, 0.7);
    [boneSwitch addTarget:self action:@selector(boneToggled:) forControlEvents:UIControlEventValueChanged];
    [_fullView addSubview:boneSwitch];
    cy += 28;

    // ── 方框开关 ──
    UILabel *l4 = [[UILabel alloc] initWithFrame:CGRectMake(14, cy, 80, 26)];
    l4.text = @"方框";
    l4.textColor = [UIColor whiteColor];
    l4.font = [UIFont systemFontOfSize:13];
    [_fullView addSubview:l4];

    UISwitch *boxSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(w - 58, cy - 1, 48, 26)];
    boxSwitch.on = [ESPManager sharedManager].showBox;
    boxSwitch.transform = CGAffineTransformMakeScale(0.7, 0.7);
    [boxSwitch addTarget:self action:@selector(boxToggled:) forControlEvents:UIControlEventValueChanged];
    [_fullView addSubview:boxSwitch];
    cy += 28;

    // 状态标签
    _aimStatusLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, cy, w - 20, 18)];
    _aimStatusLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    _aimStatusLabel.font = [UIFont systemFontOfSize:10];
    _aimStatusLabel.text = [AimAssistManager sharedManager].enabled ? @"自瞄: 开 | 目标: 头部" : @"自瞄: 关";
    [_fullView addSubview:_aimStatusLabel];
    cy += 20;

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, cy, w - 20, 18)];
    _statusLabel.textColor = [UIColor colorWithWhite:0.5 alpha:1.0];
    _statusLabel.font = [UIFont systemFontOfSize:9];
    _statusLabel.text = @"右半屏瞄准 | 自动锁定FOV内敌人";
    [_fullView addSubview:_statusLabel];

    // 1Hz 数据源状态刷新（内存模型 / 屏幕识别）
    _statusTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                    target:self
                                                  selector:@selector(refreshStatus)
                                                  userInfo:nil
                                                   repeats:YES];
    [self refreshStatus];
}

- (void)refreshStatus {
    _statusLabel.text = [NSString stringWithFormat:@"数据源: %@ | 右半屏瞄准",
                         [ESPManager sharedManager].dataSource ?: @"屏幕识别"];
}

- (void)dealloc {
    [_statusTimer invalidate];
}

// ── 最小化模式 ──
- (void)setupMinimizedMode {
    _minimizedView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
    _minimizedView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    _minimizedView.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.85];
    _minimizedView.layer.cornerRadius = 22;
    _minimizedView.layer.shadowColor = [UIColor blackColor].CGColor;
    _minimizedView.layer.shadowOpacity = 0.6;
    _minimizedView.layer.shadowRadius = 8;
    _minimizedView.layer.shadowOffset = CGSizeMake(0, 2);
    _minimizedView.hidden = YES;
    [self addSubview:_minimizedView];

    UILabel *icon = [[UILabel alloc] initWithFrame:_minimizedView.bounds];
    icon.text = @"⚡";
    icon.textAlignment = NSTextAlignmentCenter;
    icon.font = [UIFont systemFontOfSize:20];
    [_minimizedView addSubview:icon];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(restore)];
    [_minimizedView addGestureRecognizer:tap];
}

- (void)showFullMode {
    _fullView.hidden = NO;
    _minimizedView.hidden = YES;
    CGRect f = self.frame;
    f.size = CGSizeMake(170, 210);
    self.frame = f;
    _fullView.frame = self.bounds;
    [self layoutSubviews];
}

- (void)minimize {
    _minimized = YES;
    _fullView.hidden = YES;
    _minimizedView.hidden = NO;
    _savedCenter = self.center;
    CGRect f = self.frame;
    f.size = CGSizeMake(44, 44);
    self.frame = f;
    _minimizedView.frame = self.bounds;
    [self layoutSubviews];
}

- (void)restore {
    _minimized = NO;
    self.center = _savedCenter;
    [self showFullMode];
}

// ── 控件事件 ──
- (void)aimToggled:(UISwitch *)s {
    [AimAssistManager sharedManager].enabled = s.on;
    [[AimAssistManager sharedManager] saveSettings];
    _aimStatusLabel.text = s.on ? @"自瞄: 开 | 目标: 头部" : @"自瞄: 关";
}

- (void)espToggled:(UISwitch *)s {
    [ESPManager sharedManager].espEnabled = s.on;
}

- (void)boneToggled:(UISwitch *)s {
    [ESPManager sharedManager].showSkeleton = s.on;
}

- (void)boxToggled:(UISwitch *)s {
    [ESPManager sharedManager].showBox = s.on;
}

// ── 拖拽 ──
- (void)handlePan:(UIPanGestureRecognizer *)g {
    if (_minimized) return;
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
            CGSize screen = self.superview.bounds.size;
            CGFloat halfW = self.bounds.size.width * 0.5;
            CGFloat halfH = self.bounds.size.height * 0.5;
            newCenter.x = MAX(halfW, MIN(screen.width - halfW, newCenter.x));
            newCenter.y = MAX(halfH, MIN(screen.height - halfH, newCenter.y));
            self.center = newCenter;
            break;
        }
        default:
            break;
    }
}

@end

// ═══════════════════════════════════════════════════════════════════════════
//  NativeOverlay 主实现
// ═══════════════════════════════════════════════════════════════════════════
@implementation NativeOverlay {
    OverlayWindow *_overlayWindow;  // 控制面板窗口
    ControlPanel *_panelView;       // 控制面板
    ESPDrawView *_espView;         // ESP 绘制视图（添加到游戏主窗口）
}

+ (instancetype)sharedOverlay {
    static NativeOverlay *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[NativeOverlay alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // 顺序：先建窗口 → 面板 → ESP 视图（ESP 挂到 OverlayWindow，
        // 这样 keyWindow 截图不会包含 ESP 绘制 → 杜绝检测自反馈）
        [self setupPanelWindow];
        [self setupPanel];
        [self setupESPView];
    }
    return self;
}

// ── 创建 ESP 绘制视图，挂到独立 OverlayWindow（不参与 keyWindow 截图） ──
- (void)setupESPView {
    if (!_overlayWindow) return;
    _espView = [[ESPDrawView alloc] initWithFrame:_overlayWindow.bounds];
    _espView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_overlayWindow insertSubview:_espView belowSubview:_panelView];
}

// ── 创建控制面板窗口 ──
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
        if (!scene) {
            for (UIScene *s in scenes) {
                if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
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

// ── 创建控制面板 ──
- (void)setupPanel {
    CGFloat pw = 170, ph = 210;
    CGFloat px = 16, py = 100;

    _panelView = [[ControlPanel alloc] initWithFrame:CGRectMake(px, py, pw, ph)];
    _panelView.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
    _overlayWindow.controlView = _panelView;
    [_overlayWindow addSubview:_panelView];
}

// ── 公共接口 ──
- (void)show {
    _overlayWindow.hidden = NO;
    if (!_espView || !_espView.superview) {
        [self setupESPView];
    }
    _espView.frame = _overlayWindow.bounds;
    // 启动屏幕扫描器（基于计算机视觉检测真实敌人）
    [[ScreenScanner sharedScanner] startScanning];
}

- (void)hide {
    _overlayWindow.hidden = YES;
    [_espView removeFromSuperview];
    _espView = nil;
    [[ScreenScanner sharedScanner] stopScanning];
}

- (BOOL)isVisible {
    return !_overlayWindow.hidden;
}

- (void)setNeedsDisplay {
    [_espView setNeedsDisplay];
}

- (CGRect)panelFrame {
    if (!_panelView || _panelView.hidden || _panelView.alpha < 0.01) return CGRectNull;
    return _panelView.frame;
}

@end