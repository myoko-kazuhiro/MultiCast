#import "ExceptionCatcher.h"

@implementation ExceptionCatcher

+ (BOOL)catchException:(void(^)(void))tryBlock error:(__autoreleasing NSError **)error {
    @try {
        tryBlock();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithDictionary:exception.userInfo ?: @{}];
            userInfo[NSLocalizedDescriptionKey] = exception.reason ?: @"Unknown Exception";
            *error = [NSError errorWithDomain:exception.name code:0 userInfo:userInfo];
        }
        return NO;
    }
}

@end
