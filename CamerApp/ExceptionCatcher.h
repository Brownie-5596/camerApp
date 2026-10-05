#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs a block and turns an Objective-C exception (which Swift can't catch) into a message.
@interface ExceptionCatcher : NSObject
+ (nullable NSString *)catching:(void (NS_NOESCAPE ^)(void))block;
@end

NS_ASSUME_NONNULL_END
