#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ExceptionCatcher : NSObject

+ (BOOL)catchException:(void(^)(void))tryBlock error:(__autoreleasing NSError **)error NS_SWIFT_NOTHROW;

@end

NS_ASSUME_NONNULL_END
