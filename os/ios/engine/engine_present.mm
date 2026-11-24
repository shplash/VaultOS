#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

#include "engine_present.h"
#include "launcher/launcher.h"

@interface VaultPresentView : UIView
@end

@implementation VaultPresentView

+ (Class)layerClass
{
    return [CAMetalLayer class];
}

@end

namespace {

NSString* const kPresentShaderSource =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct VaultPresentVertex {\n"
     "    float4 position [[position]];\n"
     "    float2 uv;\n"
     "};\n"
     "vertex VaultPresentVertex vault_present_vertex(uint vertexID [[vertex_id]]) {\n"
     "    float2 corner = float2((vertexID << 1) & 2, vertexID & 2);\n"
     "    VaultPresentVertex out;\n"
     "    out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);\n"
     "    out.uv = float2(corner.x, 1.0 - corner.y);\n"
     "    return out;\n"
     "}\n"
     "float3 vault_decode(float3 c) {\n"
     "    return c * c;\n"
     "}\n"
     "float3 vault_encode(float3 c) {\n"
     "    return sqrt(max(c, float3(0.0)));\n"
     "}\n"
     "float vault_mitchell(float x) {\n"
     "    x = fabs(x);\n"
     "    if (x < 1.0) {\n"
     "        return (7.0 * x * x * x - 12.0 * x * x + 5.3333333) * 0.1666667;\n"
     "    }\n"
     "    if (x < 2.0) {\n"
     "        return (-2.3333333 * x * x * x + 12.0 * x * x - 20.0 * x + 10.6666667) * 0.1666667;\n"
     "    }\n"
     "    return 0.0;\n"
     "}\n"
     "float vault_grain(float2 p, float t) {\n"
     "    return fract(sin(dot(p + float2(t * 61.7, t * 47.3), float2(12.9898, 78.233))) * 43758.5453);\n"
     "}\n"
     "fragment float4 vault_present_fragment(VaultPresentVertex in [[stage_in]],\n"
     "                                       texture2d<float> source [[texture(0)]],\n"
     "                                       constant float2& scale [[buffer(0)]],\n"
     "                                       constant int& mode [[buffer(1)]],\n"
     "                                       constant int& effects [[buffer(2)]],\n"
     "                                       constant float& time [[buffer(3)]],\n"
     "                                       sampler nearestSampler [[sampler(0)]],\n"
     "                                       sampler linearSampler [[sampler(1)]]) {\n"
     "    float2 size = float2(source.get_width(), source.get_height());\n"
     "    float2 texel = in.uv * size;\n"
     "    float2 base = floor(texel);\n"
     "    float3 rgb = float3(0.0);\n"
     "    if (mode == 0) {\n"
     "        rgb = source.sample(nearestSampler, (base + 0.5) / size).rgb;\n"
     "    } else if (mode == 1) {\n"
     "        float2 c = texel - 0.5;\n"
     "        float2 fl = floor(c);\n"
     "        float fx = c.x - fl.x;\n"
     "        float fy = c.y - fl.y;\n"
     "        float wx0 = vault_mitchell(1.0 + fx);\n"
     "        float wx1 = vault_mitchell(fx);\n"
     "        float wx2 = vault_mitchell(1.0 - fx);\n"
     "        float wx3 = vault_mitchell(2.0 - fx);\n"
     "        float wy0 = vault_mitchell(1.0 + fy);\n"
     "        float wy1 = vault_mitchell(fy);\n"
     "        float wy2 = vault_mitchell(1.0 - fy);\n"
     "        float wy3 = vault_mitchell(2.0 - fy);\n"
     "        float sx = wx1 + wx2;\n"
     "        float sy = wy1 + wy2;\n"
     "        float ox = sx != 0.0 ? wx2 / sx : 0.0;\n"
     "        float oy = sy != 0.0 ? wy2 / sy : 0.0;\n"
     "        float px0 = (fl.x - 0.5) / size.x;\n"
     "        float px1 = (fl.x + 0.5 + ox) / size.x;\n"
     "        float px2 = (fl.x + 2.5) / size.x;\n"
     "        float py0 = (fl.y - 0.5) / size.y;\n"
     "        float py1 = (fl.y + 0.5 + oy) / size.y;\n"
     "        float py2 = (fl.y + 2.5) / size.y;\n"
     "        float3 blurred = float3(0.0);\n"
     "        blurred += vault_decode(source.sample(linearSampler, float2(px0, py0)).rgb) * (wx0 * wy0);\n"
     "        blurred += vault_decode(source.sample(linearSampler, float2(px1, py0)).rgb) * (sx * wy0);\n"
     "        blurred += vault_decode(source.sample(linearSampler, float2(px2, py0)).rgb) * (wx3 * wy0);\n"
     "        blurred += vault_decode(source.sample(linearSampler, float2(px0, py1)).rgb) * (wx0 * sy);\n"
     "        blurred += vault_decode(source.sample(linearSampler, float2(px1, py1)).rgb) * (sx * sy);\n"
     "        blurred += vault_decode(source.sample(linearSampler, float2(px2, py1)).rgb) * (wx3 * sy);\n"
     "        blurred += vault_decode(source.sample(linearSampler, float2(px0, py2)).rgb) * (wx0 * wy3);\n"
     "        blurred += vault_decode(source.sample(linearSampler, float2(px1, py2)).rgb) * (sx * wy3);\n"
     "        blurred += vault_decode(source.sample(linearSampler, float2(px2, py2)).rgb) * (wx3 * wy3);\n"
     "        rgb = vault_encode(blurred);\n"
     "    } else {\n"
     "        float2 sharpScale = max(scale, float2(1.0));\n"
     "        float2 pixelStep = 1.0 / (size * sharpScale);\n"
     "        float2 offsets[4] = { float2(-0.375, -0.125), float2(0.125, -0.375),\n"
     "                              float2(0.375, 0.125), float2(-0.125, 0.375) };\n"
     "        float3 sharp = float3(0.0);\n"
     "        for (int i = 0; i < 4; i++) {\n"
     "            float2 t = (in.uv + offsets[i] * pixelStep) * size;\n"
     "            float2 b = floor(t);\n"
     "            float2 phase = clamp((t - b - 0.5) / sharpScale + 0.5, float2(0.0), float2(1.0));\n"
     "            sharp += vault_decode(source.sample(linearSampler, (b + phase) / size).rgb);\n"
     "        }\n"
     "        rgb = vault_encode(sharp * 0.25);\n"
     "    }\n"
     "    if ((effects & 1) != 0) {\n"
     "        rgb += (vault_grain(base, time) - 0.5) * 0.06;\n"
     "    }\n"
     "    if ((effects & 2) != 0) {\n"
     "        float2 d = in.uv - 0.5;\n"
     "        rgb *= 1.0 - 0.45 * smoothstep(0.30, 1.05, length(d));\n"
     "    }\n"
     "    if ((effects & 4) != 0) {\n"
     "        rgb *= 0.86 + 0.14 * (0.5 + 0.5 * cos(in.position.y * 3.14159265));\n"
     "    }\n"
     "    return float4(clamp(rgb, float3(0.0), float3(1.0)), 1.0);\n"
     "}\n";

id<MTLDevice> gPresentDevice = nil;
id<MTLCommandQueue> gPresentQueue = nil;
id<MTLRenderPipelineState> gPresentPipeline = nil;
id<MTLSamplerState> gPresentNearestSampler = nil;
id<MTLSamplerState> gPresentLinearSampler = nil;
id<MTLTexture> gPresentTexture = nil;
VaultPresentView* gPresentView = nil;
CAMetalLayer* gPresentLayer = nil;
NSString* gPresentModeKey = nil;
NSString* gPresentFrameRateKey = nil;
NSString* gPresentGrainKey = nil;
NSString* gPresentVignetteKey = nil;
NSString* gPresentScanlineKey = nil;
UILabel* gPresentTestLabel = nil;
NSString* gPresentTestShown = nil;
CFAbsoluteTime gPresentLast = 0;
CFAbsoluteTime gPresentStart = 0;
int gPresentTextureWidth = 0;
int gPresentTextureHeight = 0;
bool gPresentUnavailable = false;

void presentPrepareKeys()
{
    if (gPresentModeKey != nil) {
        return;
    }

    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    NSString* game = [defaults stringForKey:@"launcher.game"];
    if (game.length == 0) {
        game = @"fallout1";
    }

    gPresentModeKey = [NSString stringWithFormat:@"launcher.%@.imageScaling", game];
    gPresentFrameRateKey = [NSString stringWithFormat:@"launcher.%@.frameRate", game];
    gPresentGrainKey = [NSString stringWithFormat:@"launcher.%@.shaderGrain", game];
    gPresentVignetteKey = [NSString stringWithFormat:@"launcher.%@.shaderVignette", game];
    gPresentScanlineKey = [NSString stringWithFormat:@"launcher.%@.shaderScanlines", game];
}

int presentMode()
{
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    presentPrepareKeys();

    if ([defaults objectForKey:gPresentModeKey] == nil) {
        return 2;
    }

    NSInteger mode = [defaults integerForKey:gPresentModeKey];
    if (mode < 0 || mode > 2) {
        return 2;
    }

    return (int)mode;
}

int presentEffects()
{
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    presentPrepareKeys();

    int mask = 0;
    if ([defaults boolForKey:gPresentGrainKey]) {
        mask |= 1;
    }
    if ([defaults boolForKey:gPresentVignetteKey]) {
        mask |= 2;
    }
    if ([defaults boolForKey:gPresentScanlineKey]) {
        mask |= 4;
    }

    return mask;
}

int presentFrameRate()
{
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    presentPrepareKeys();

    if ([defaults objectForKey:gPresentFrameRateKey] == nil) {
        return 60;
    }

    return [defaults integerForKey:gPresentFrameRateKey] == 30 ? 30 : 60;
}

void presentPace()
{
    if (fallout_ios_screen() != 0 || fallout_ios_movie_state() != 0 || presentFrameRate() > 30) {
        gPresentLast = 0;
        return;
    }

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (gPresentLast > 0) {
        CFAbsoluteTime target = gPresentLast + (1.0 / 30.0);
        if (target > now) {
            [NSThread sleepForTimeInterval:(NSTimeInterval)(target - now)];
            now = CFAbsoluteTimeGetCurrent();
        }
    }
    gPresentLast = now;
}

void presentTestOverlay(int mode, int effects)
{
    if (gPresentTestLabel == nil) {
        return;
    }

    NSString* scaling = mode == 0 ? @"NONE" : (mode == 1 ? @"SMOOTH" : @"ENHANCED");
    NSString* text = [NSString stringWithFormat:@"[%@] GRAIN   [%@] VIGNETTE   [%@] SCANLINES\n%@ · %d FPS · shader test",
                      (effects & 1) != 0 ? @"x" : @" ",
                      (effects & 2) != 0 ? @"x" : @" ",
                      (effects & 4) != 0 ? @"x" : @" ",
                      scaling,
                      presentFrameRate()];

    BOOL hidden = fallout_ios_movie_state() != 0;
    if (gPresentTestShown != nil
        && [gPresentTestShown isEqualToString:text]
        && gPresentTestLabel.hidden == hidden) {
        return;
    }

    gPresentTestLabel.hidden = hidden;
    gPresentTestShown = text;
    gPresentTestLabel.text = text;

    CGSize fitted = [gPresentTestLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
    UIEdgeInsets insets = gPresentView.safeAreaInsets;
    gPresentTestLabel.frame = CGRectMake(14.0 + insets.left,
                                         14.0 + insets.top,
                                         ceil(fitted.width) + 18.0,
                                         ceil(fitted.height) + 12.0);
}

UIWindow* presentWindow()
{
    UIApplication* application = [UIApplication sharedApplication];
    for (UIWindow* window in application.windows) {
        if (window.hidden) {
            continue;
        }
        if (window.windowLevel != UIWindowLevelNormal) {
            continue;
        }
        return window;
    }

    return nil;
}

bool presentResourcesReady()
{
    if (gPresentUnavailable) {
        return false;
    }

    if (gPresentDevice == nil) {
        gPresentDevice = MTLCreateSystemDefaultDevice();
        if (gPresentDevice == nil) {
            gPresentUnavailable = true;
            return false;
        }

        gPresentQueue = [gPresentDevice newCommandQueue];
        if (gPresentQueue == nil) {
            gPresentUnavailable = true;
            return false;
        }

        NSError* error = nil;
        id<MTLLibrary> library = [gPresentDevice newLibraryWithSource:kPresentShaderSource
                                                              options:nil
                                                                error:&error];
        if (library == nil) {
            gPresentUnavailable = true;
            return false;
        }

        MTLRenderPipelineDescriptor* descriptor = [[MTLRenderPipelineDescriptor alloc] init];
        descriptor.vertexFunction = [library newFunctionWithName:@"vault_present_vertex"];
        descriptor.fragmentFunction = [library newFunctionWithName:@"vault_present_fragment"];
        descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        gPresentPipeline = [gPresentDevice newRenderPipelineStateWithDescriptor:descriptor error:&error];
        if (gPresentPipeline == nil) {
            gPresentUnavailable = true;
            return false;
        }

        MTLSamplerDescriptor* nearest = [[MTLSamplerDescriptor alloc] init];
        nearest.minFilter = MTLSamplerMinMagFilterNearest;
        nearest.magFilter = MTLSamplerMinMagFilterNearest;
        nearest.sAddressMode = MTLSamplerAddressModeClampToEdge;
        nearest.tAddressMode = MTLSamplerAddressModeClampToEdge;
        gPresentNearestSampler = [gPresentDevice newSamplerStateWithDescriptor:nearest];

        MTLSamplerDescriptor* linear = [[MTLSamplerDescriptor alloc] init];
        linear.minFilter = MTLSamplerMinMagFilterLinear;
        linear.magFilter = MTLSamplerMinMagFilterLinear;
        linear.sAddressMode = MTLSamplerAddressModeClampToEdge;
        linear.tAddressMode = MTLSamplerAddressModeClampToEdge;
        gPresentLinearSampler = [gPresentDevice newSamplerStateWithDescriptor:linear];

        if (gPresentNearestSampler == nil || gPresentLinearSampler == nil) {
            gPresentUnavailable = true;
            return false;
        }

        gPresentStart = CFAbsoluteTimeGetCurrent();
    }

    UIWindow* window = presentWindow();
    if (window == nil) {
        return false;
    }

    if (gPresentView == nil) {
        gPresentView = [[VaultPresentView alloc] initWithFrame:window.bounds];
        gPresentView.userInteractionEnabled = NO;
        gPresentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        gPresentView.backgroundColor = [UIColor blackColor];
        gPresentLayer = (CAMetalLayer*)gPresentView.layer;
        gPresentLayer.device = gPresentDevice;
        gPresentLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        gPresentLayer.framebufferOnly = YES;
        gPresentLayer.opaque = YES;
    }

    if (gPresentTestLabel == nil) {
        gPresentTestLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        gPresentTestLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
        gPresentTestLabel.textColor = [UIColor colorWithWhite:0.90 alpha:1.0];
        gPresentTestLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightSemibold];
        gPresentTestLabel.textAlignment = NSTextAlignmentCenter;
        gPresentTestLabel.numberOfLines = 2;
        gPresentTestLabel.userInteractionEnabled = NO;
        gPresentTestLabel.layer.cornerRadius = 6;
        gPresentTestLabel.layer.masksToBounds = YES;
        [gPresentView addSubview:gPresentTestLabel];
    }

    if (gPresentView.superview != window) {
        [gPresentView removeFromSuperview];

        NSUInteger position = 0;
        UIView* engineView = window.rootViewController.view;
        if (engineView != nil) {
            NSUInteger index = [window.subviews indexOfObject:engineView];
            if (index != NSNotFound) {
                position = index + 1;
            }
        }

        [window insertSubview:gPresentView atIndex:position];
    }

    gPresentView.frame = window.bounds;

    return true;
}

}

int fallout_engine_present_frame(const void* pixels, int pitch, int width, int height)
{
    if (pixels == NULL || pitch <= 0 || width <= 0 || height <= 0) {
        return 0;
    }

    @autoreleasepool {
        presentPace();

        if (!presentResourcesReady()) {
            return 0;
        }

        UIWindow* window = gPresentView.window;
        if (window == nil) {
            return 0;
        }

        CGFloat scale = window.screen.nativeScale;
        if (scale <= 0) {
            scale = gPresentView.contentScaleFactor;
        }

        CGSize drawableSize = CGSizeMake(gPresentView.bounds.size.width * scale,
                                         gPresentView.bounds.size.height * scale);
        if (drawableSize.width < 1 || drawableSize.height < 1) {
            return 0;
        }

        if (!CGSizeEqualToSize(gPresentLayer.drawableSize, drawableSize)) {
            gPresentLayer.drawableSize = drawableSize;
            gPresentLayer.contentsScale = scale;
        }

        if (gPresentTexture == nil || gPresentTextureWidth != width || gPresentTextureHeight != height) {
            MTLTextureDescriptor* descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                                  width:(NSUInteger)width
                                                                                                 height:(NSUInteger)height
                                                                                              mipmapped:NO];
            descriptor.usage = MTLTextureUsageShaderRead;
            gPresentTexture = [gPresentDevice newTextureWithDescriptor:descriptor];
            gPresentTextureWidth = width;
            gPresentTextureHeight = height;
            if (gPresentTexture == nil) {
                return 0;
            }
        }

        id<CAMetalDrawable> drawable = [gPresentLayer nextDrawable];
        if (drawable == nil) {
            return 1;
        }

        [gPresentTexture replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)width, (NSUInteger)height)
                           mipmapLevel:0
                             withBytes:pixels
                           bytesPerRow:(NSUInteger)pitch];

        CGFloat gameAspect = (CGFloat)width / (CGFloat)height;
        CGFloat drawableAspect = drawableSize.width / drawableSize.height;
        CGFloat fitWidth = drawableSize.width;
        CGFloat fitHeight = drawableSize.height;
        if (drawableAspect > gameAspect) {
            fitWidth = drawableSize.height * gameAspect;
        } else {
            fitHeight = drawableSize.width / gameAspect;
        }

        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = drawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

        id<MTLCommandBuffer> commandBuffer = [gPresentQueue commandBuffer];
        id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];

        MTLViewport viewport;
        viewport.originX = (drawableSize.width - fitWidth) * 0.5;
        viewport.originY = (drawableSize.height - fitHeight) * 0.5;
        viewport.width = fitWidth;
        viewport.height = fitHeight;
        viewport.znear = 0.0;
        viewport.zfar = 1.0;
        [encoder setViewport:viewport];

        [encoder setRenderPipelineState:gPresentPipeline];
        [encoder setFragmentTexture:gPresentTexture atIndex:0];
        [encoder setFragmentSamplerState:gPresentNearestSampler atIndex:0];
        [encoder setFragmentSamplerState:gPresentLinearSampler atIndex:1];
        float ratios[2] = { (float)(fitWidth / (CGFloat)width), (float)(fitHeight / (CGFloat)height) };
        [encoder setFragmentBytes:ratios length:sizeof(ratios) atIndex:0];
        int mode = presentMode();
        [encoder setFragmentBytes:&mode length:sizeof(mode) atIndex:1];
        int effects = presentEffects();
        [encoder setFragmentBytes:&effects length:sizeof(effects) atIndex:2];
        float elapsed = (float)(CFAbsoluteTimeGetCurrent() - gPresentStart);
        [encoder setFragmentBytes:&elapsed length:sizeof(elapsed) atIndex:3];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];

        [commandBuffer presentDrawable:drawable];
        [commandBuffer commit];

        presentTestOverlay(mode, effects);

        return 1;
    }
}
