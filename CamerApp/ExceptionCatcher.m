#import "ExceptionCatcher.h"

@implementation ExceptionCatcher
+ (nullable NSString *)catching:(void (NS_NOESCAPE ^)(void))block {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @""];
    }
}
@end
