#import "ESPManager.h"

@implementation ESPPlayerData
@end

@interface ESPManager ()
@property (nonatomic, strong) NSArray<ESPPlayerData *> *players;
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@implementation ESPManager

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

@end