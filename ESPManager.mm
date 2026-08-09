#import "ESPManager.h"

@implementation ESPPlayerData
@end

@interface ESPManager ()
@property (nonatomic, strong) NSArray<ESPPlayerData *> *players;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, assign) BOOL memoryActive;
@property (nonatomic, strong) NSString *dataSource;
@end

@implementation ESPManager

@synthesize memoryActive = _memoryActive;
@synthesize dataSource = _dataSource;

+ (instancetype)sharedManager {
    static ESPManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ESPManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _players = @[];
        _queue = dispatch_queue_create("com.aimassist.esp", DISPATCH_QUEUE_CONCURRENT);
        _espEnabled    = YES;
        _showSkeleton  = YES;
        _showBox       = YES;
        _showHealth    = YES;
        _showName      = YES;
        _showCrosshair = YES;
        _showFOV       = YES;
        _fovRadius     = 200.0f;
        _memoryActive  = NO;
        _dataSource    = @"屏幕识别";
    }
    return self;
}

- (void)updatePlayers:(NSArray<ESPPlayerData *> *)players {
    dispatch_barrier_async(_queue, ^{
        self->_players = [players copy];
    });
}

- (NSArray<ESPPlayerData *> *)currentPlayers {
    __block NSArray *result;
    dispatch_sync(_queue, ^{
        result = [self->_players copy];
    });
    return result;
}

// ── 数据源协调（barrier 保护，跨线程安全） ──
- (void)setMemoryActive:(BOOL)active {
    dispatch_barrier_async(_queue, ^{ self->_memoryActive = active; });
}

- (BOOL)memoryActive {
    __block BOOL r;
    dispatch_sync(_queue, ^{ r = self->_memoryActive; });
    return r;
}

- (void)setDataSource:(NSString *)ds {
    NSString *copy = [ds copy];
    dispatch_barrier_async(_queue, ^{ self->_dataSource = copy; });
}

- (NSString *)dataSource {
    __block NSString *r;
    dispatch_sync(_queue, ^{ r = self->_dataSource; });
    return r;
}

@end