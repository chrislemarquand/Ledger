#import <Foundation/Foundation.h>

#if __has_attribute(swift_private)
#define AC_SWIFT_PRIVATE __attribute__((swift_private))
#else
#define AC_SWIFT_PRIVATE
#endif

/// The resource bundle ID.
static NSString * const ACBundleID AC_SWIFT_PRIVATE = @"com.chrislemarquand.Lattice";

/// The "BrandAccent" asset catalog color resource.
static NSString * const ACColorNameBrandAccent AC_SWIFT_PRIVATE = @"BrandAccent";

/// The "BrandAccentSoft" asset catalog color resource.
static NSString * const ACColorNameBrandAccentSoft AC_SWIFT_PRIVATE = @"BrandAccentSoft";

/// The "BrandAccentStrong" asset catalog color resource.
static NSString * const ACColorNameBrandAccentStrong AC_SWIFT_PRIVATE = @"BrandAccentStrong";

#undef AC_SWIFT_PRIVATE
