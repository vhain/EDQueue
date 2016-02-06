//
//  EDQueue.m
//  queue
//
//  Created by Andrew Sliwinski on 6/29/12.
//  Copyright (c) 2012 Andrew Sliwinski. All rights reserved.
//

#import "EDQueue.h"
#import "EDQueueStorageEngine.h"

NSString *const EDQueueDidStart = @"EDQueueDidStart";
NSString *const EDQueueDidStop = @"EDQueueDidStop";
NSString *const EDQueueJobDidSucceed = @"EDQueueJobDidSucceed";
NSString *const EDQueueJobDidFail = @"EDQueueJobDidFail";
NSString *const EDQueueDidDrain = @"EDQueueDidDrain";

@interface EDQueue ()
{
    BOOL _isRunning;
    NSUInteger _activeTaskCount;
    NSUInteger _retryLimit;
    NSUInteger _concurrency;

    dispatch_queue_t _queue;
}

@property (nonatomic) EDQueueStorageEngine *engine;

@end

//

@implementation EDQueue

@synthesize isRunning = _isRunning;
@synthesize activeTaskCount = _activeTaskCount;
@synthesize retryLimit = _retryLimit;
@synthesize concurrency = _concurrency;

#pragma mark - Singleton

+ (EDQueue *)sharedInstance
{
    static EDQueue *singleton = nil;
    static dispatch_once_t once = 0;
    dispatch_once(&once, ^{
        singleton = [[self alloc] init];
    });
    return singleton;
}

#pragma mark - Init

- (id)init
{
    self = [super init];
    if (self) {
        _engine      = [[EDQueueStorageEngine alloc] init];
        _retryLimit  = 4;
        _concurrency = 6;
        _queue       = dispatch_queue_create("EDQueue.Queue", DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

- (void)dealloc
{    
    self.delegate = nil;
    _engine = nil;
}

#pragma mark - Public methods

/**
 * Adds a new job to the queue.
 *
 * @param {id} Data
 * @param {NSString} Task label
 *
 * @return {void}
 */
- (void)enqueueWithData:(id)data forTask:(NSString *)task
{
    if (data == nil) data = @{};
    dispatch_barrier_async(_queue, ^{
      [self.engine createJob:data forTask:task];
    });
    [self tick];
}

/**
 * Returns true if a job exists for this task.
 *
 * @param {NSString} Task label
 *
 * @return {Boolean}
 */
- (BOOL)jobExistsForTask:(NSString *)task
{
    BOOL jobExists = [self.engine jobExistsForTask:task];
    return jobExists;
}

/**
 * Returns the list of jobs for this 
 *
 * @param {NSString} Task label
 *
 * @return {NSArray}
 */
- (NSDictionary *)nextJobForTask:(NSString *)task
{
    NSDictionary *nextJobForTask = [self.engine fetchJobForTask:task];
    return nextJobForTask;
}

/**
 * Returns the number of jobs for task
 *
 * @param {NSString} Task label
 *
 * @return {NSUinteger}
 */
- (NSUInteger)jobCountForTask:(NSString *)task
{
    return [self.engine jobCountForTask:task];
}

/**
 * Returns the total number of jobs
 *
 * @return {NSUinteger}
 */
- (NSUInteger)totalJobCount
{
    return [self.engine fetchJobCount];
}

/**
 * Starts the queue.
 *
 * @return {void}
 */
- (void)start
{
    if (!self.isRunning) {
        _isRunning = YES;
        [self.engine unmarkAllJobs];
        [self tick];
        [self performSelectorOnMainThread:@selector(postNotification:) withObject:[NSDictionary dictionaryWithObjectsAndKeys:EDQueueDidStart, @"name", nil, @"data", nil] waitUntilDone:false];
    }
}

/**
 * Stops the queue.
 * @note Jobs that have already started will continue to process even after stop has been called.
 *
 * @return {void}
 */
- (void)stop
{
    if (self.isRunning) {
        _isRunning = NO;
        [self performSelectorOnMainThread:@selector(postNotification:) withObject:[NSDictionary dictionaryWithObjectsAndKeys:EDQueueDidStop, @"name", nil, @"data", nil] waitUntilDone:false];
    }
}



/**
 * Empties the queue.
 * @note Jobs that have already started will continue to process even after empty has been called.
 *
 * @return {void}
 */
- (void)empty
{
    dispatch_barrier_async(_queue, ^{
        [self.engine removeAllJobs];
    });
}


#pragma mark - Private methods

/**
 * Checks the queue for available jobs, sends them to the processor delegate, and then handles the response.
 *
 * @return {void}
 */
- (void)tick
{
    dispatch_barrier_async(_queue, ^{
        if (self.isRunning && self.concurrency > self.activeTaskCount && [self.engine fetchJobCount] > 0) {
            NSArray *jobs = [self.engine fetchJobsAndMark:self.concurrency - self.activeTaskCount];
            if (jobs == nil || [jobs count] < 1) return;
            _activeTaskCount += [jobs count];
          
            if ([self.delegate respondsToSelector:@selector(queue:processJob:completion:)]) {
                for (NSDictionary *job in jobs) {
                    dispatch_async(_queue, ^{
                        [self.delegate queue:self processJob:job completion:^(EDQueueResult result) {
                            dispatch_async(_queue, ^{
                                [self processJob:job withResult:result];
                            });
                        }];
                    });
                }
            } else {
                for (NSDictionary *job in jobs) {
                    dispatch_async(_queue, ^{
                        EDQueueResult result = [self.delegate queue:self processJob:job];
                        [self processJob:job withResult:result];
                    });
                }
            }
        }
    });
}

- (void)processJob:(NSDictionary*)job withResult:(EDQueueResult)result
{
    dispatch_barrier_async(_queue, ^{
        // Check result
        switch (result) {
            case EDQueueResultSuccess:
                [self performSelectorOnMainThread:@selector(postNotification:) withObject:[NSDictionary dictionaryWithObjectsAndKeys:EDQueueJobDidSucceed, @"name", job, @"data", nil] waitUntilDone:false];
                [self.engine removeJob:[job objectForKey:@"id"]];
                break;
            case EDQueueResultFail:
                [self performSelectorOnMainThread:@selector(postNotification:) withObject:[NSDictionary dictionaryWithObjectsAndKeys:EDQueueJobDidFail, @"name", job, @"data", nil] waitUntilDone:true];
                NSUInteger currentAttempt = [[job objectForKey:@"attempts"] intValue] + 1;
                if (currentAttempt < self.retryLimit) {
                    [self.engine incrementAttemptForJob:[job objectForKey:@"id"]];
                } else {
                    [self.engine removeJob:[job objectForKey:@"id"]];
                }
                break;
            case EDQueueResultCritical:
                [self performSelectorOnMainThread:@selector(postNotification:) withObject:[NSDictionary dictionaryWithObjectsAndKeys:EDQueueJobDidFail, @"name", job, @"data", nil] waitUntilDone:false];
                [self errorWithMessage:@"Critical error. Job canceled."];
                [self.engine removeJob:[job objectForKey:@"id"]];
                break;
        }
        
        // Clean-up
        _activeTaskCount--;
      
        // Drain
        if ([self.engine fetchJobCount] == 0) {
            [self performSelectorOnMainThread:@selector(postNotification:) withObject:[NSDictionary dictionaryWithObjectsAndKeys:EDQueueDidDrain, @"name", nil, @"data", nil] waitUntilDone:false];
        } else {
            [self performSelectorOnMainThread:@selector(tick) withObject:nil waitUntilDone:false];
        }
    });
}

/**
 * Posts a notification (used to keep notifications on the main thread).
 *
 * @param {NSDictionary} Object
 *                          - name: Notification name
 *                          - data: Data to be attached to notification
 *
 * @return {void}
 */
- (void)postNotification:(NSDictionary *)object
{
    [[NSNotificationCenter defaultCenter] postNotificationName:[object objectForKey:@"name"] object:[object objectForKey:@"data"]];
}

/**
 * Writes an error message to the log.
 *
 * @param {NSString} Message
 *
 * @return {void}
 */
- (void)errorWithMessage:(NSString *)message
{
    NSLog(@"EDQueue Error: %@", message);
}

@end
