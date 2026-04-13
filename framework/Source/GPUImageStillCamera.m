// 2448x3264 pixel image = 31,961,088 bytes for uncompressed RGBA

#import "GPUImageStillCamera.h"

void stillImageDataReleaseCallback(void *releaseRefCon, const void *baseAddress)
{
    free((void *)baseAddress);
}

void GPUImageCreateResizedSampleBuffer(CVPixelBufferRef cameraFrame, CGSize finalSize, CMSampleBufferRef *sampleBuffer)
{
    // CVPixelBufferCreateWithPlanarBytes for YUV input
    
    CGSize originalSize = CGSizeMake(CVPixelBufferGetWidth(cameraFrame), CVPixelBufferGetHeight(cameraFrame));

    CVPixelBufferLockBaseAddress(cameraFrame, 0);
    GLubyte *sourceImageBytes =  CVPixelBufferGetBaseAddress(cameraFrame);
    CGDataProviderRef dataProvider = CGDataProviderCreateWithData(NULL, sourceImageBytes, CVPixelBufferGetBytesPerRow(cameraFrame) * originalSize.height, NULL);
    CGColorSpaceRef genericRGBColorspace = CGColorSpaceCreateDeviceRGB();
    CGImageRef cgImageFromBytes = CGImageCreate((int)originalSize.width, (int)originalSize.height, 8, 32, CVPixelBufferGetBytesPerRow(cameraFrame), genericRGBColorspace, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst, dataProvider, NULL, NO, kCGRenderingIntentDefault);
    
    GLubyte *imageData = (GLubyte *) calloc(1, (int)finalSize.width * (int)finalSize.height * 4);
    
    CGContextRef imageContext = CGBitmapContextCreate(imageData, (int)finalSize.width, (int)finalSize.height, 8, (int)finalSize.width * 4, genericRGBColorspace,  kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGContextDrawImage(imageContext, CGRectMake(0.0, 0.0, finalSize.width, finalSize.height), cgImageFromBytes);
    CGImageRelease(cgImageFromBytes);
    CGContextRelease(imageContext);
    CGColorSpaceRelease(genericRGBColorspace);
    CGDataProviderRelease(dataProvider);
    
    CVPixelBufferRef pixel_buffer = NULL;
    CVPixelBufferCreateWithBytes(kCFAllocatorDefault, finalSize.width, finalSize.height, kCVPixelFormatType_32BGRA, imageData, finalSize.width * 4, stillImageDataReleaseCallback, NULL, NULL, &pixel_buffer);
    CMVideoFormatDescriptionRef videoInfo = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(NULL, pixel_buffer, &videoInfo);
    
    CMTime frameTime = CMTimeMake(1, 30);
    CMSampleTimingInfo timing = {frameTime, frameTime, kCMTimeInvalid};
    
    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixel_buffer, YES, NULL, NULL, videoInfo, &timing, sampleBuffer);
    CVPixelBufferUnlockBaseAddress(cameraFrame, 0);
    CFRelease(videoInfo);
    CVPixelBufferRelease(pixel_buffer);
}

@interface GPUImageStillCaptureInfo: NSObject

@property (nonatomic, strong) GPUImageOutput<GPUImageInput> *finalFilterInChain;
@property (nonatomic, copy) void (^handler)(NSError *);

@end

@implementation GPUImageStillCaptureInfo

-(instancetype)initWithFinalFilter:(GPUImageOutput<GPUImageInput> *)finalFilter handler:(void(^)(NSError *))handler {
    if (self = [super init]) {
        self.finalFilterInChain = finalFilter;
        self.handler = handler;
    }
    return self;
}

@end

@interface GPUImageStillCamera () <AVCapturePhotoCaptureDelegate>
{
    AVCapturePhotoOutput *photoOutput;
}

@property (nonatomic, strong) GPUImageStillCaptureInfo *currentCaptureInfo;
@property (nonatomic, strong) NSDictionary<NSString *, id> *photoSettingsFormat;

// Methods calling this are responsible for calling dispatch_semaphore_signal(frameRenderingSemaphore) somewhere inside the block
- (void)capturePhotoProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain withImageOnGPUHandler:(void (^)(NSError *error))block;

@end

@implementation GPUImageStillCamera {
    BOOL requiresFrontCameraTextureCacheCorruptionWorkaround;
}

@synthesize currentCaptureMetadata = _currentCaptureMetadata;
@synthesize jpegCompressionQuality = _jpegCompressionQuality;

#pragma mark -
#pragma mark Initialization and teardown

- (id)initWithSessionPreset:(NSString *)sessionPreset cameraPosition:(AVCaptureDevicePosition)cameraPosition {
    if (!(self = [self initWithSessionPreset:sessionPreset cameraPosition:cameraPosition preferredDeviceTypes:@[]]))
    {
        return nil;
    }
    
    return self;
}

- (id)initWithSessionPreset:(NSString *)sessionPreset cameraPosition:(AVCaptureDevicePosition)cameraPosition preferredDeviceTypes:(NSArray<AVCaptureDeviceType> *)deviceTypes
{
    if (!(self = [super initWithSessionPreset:sessionPreset cameraPosition:cameraPosition preferredDeviceTypes:deviceTypes]))
    {
		return nil;
    }
    
    /* Detect iOS version < 6 which require a texture cache corruption workaround */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    requiresFrontCameraTextureCacheCorruptionWorkaround = [[[UIDevice currentDevice] systemVersion] compare:@"6.0" options:NSNumericSearch] == NSOrderedAscending;
#pragma clang diagnostic pop
    
    [self.captureSession beginConfiguration];
    
    photoOutput = [[AVCapturePhotoOutput alloc] init];
   
    // Having a still photo input set to BGRA and video to YUV doesn't work well, so since I don't have YUV resizing for iPhone 4 yet, kick back to BGRA for that device
//    if (captureAsYUV && [GPUImageContext supportsFastTextureUpload])
    
    
    [self updatePhotoOutputSettings];
    
    [self.captureSession addOutput:photoOutput];
    
    [self.captureSession commitConfiguration];
    
    self.jpegCompressionQuality = 0.8;
    
    return self;
}

- (void)updatePhotoOutputSettings {
    CMVideoDimensions dimensionsOfPhoto = _inputCamera.activeFormat.highResolutionStillImageDimensions;
    CGSize sizeOfPhoto = CGSizeMake(dimensionsOfPhoto.width, dimensionsOfPhoto.height);
    CGSize scaledImageSizeToFitOnGPU = [GPUImageContext sizeThatFitsWithinATextureForSize:sizeOfPhoto];
    BOOL photoCanUseYUV = CGSizeEqualToSize(sizeOfPhoto, scaledImageSizeToFitOnGPU);

    if (photoCanUseYUV && [GPUImageContext deviceSupportsRedTextures])
    {
        BOOL supportsFullYUVRange = NO;
        NSArray *supportedPixelFormats = photoOutput.availablePhotoPixelFormatTypes;
        for (NSNumber *currentPixelFormat in supportedPixelFormats)
        {
            if ([currentPixelFormat intValue] == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            {
                supportsFullYUVRange = YES;
            }
        }
        
        if (supportsFullYUVRange)
        {
            self.photoSettingsFormat = @{ (NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) };
        }
        else
        {
            self.photoSettingsFormat = @{ (NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) };
        }
    }
    else
    {
        self.photoSettingsFormat = @{ (NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA) };
    }
}

- (id)init;
{
    if (!(self = [self initWithSessionPreset:AVCaptureSessionPresetPhoto cameraPosition:AVCaptureDevicePositionBack]))
    {
		return nil;
    }
    return self;
}

- (void)removeInputsAndOutputs;
{
    [self.captureSession removeOutput:photoOutput];
    [super removeInputsAndOutputs];
}

#pragma mark -
#pragma mark Photography controls

- (void)capturePhotoAsSampleBufferWithCompletionHandler:(void (^)(CMSampleBufferRef imageSampleBuffer, NSError *error))block
{
    NSLog(@"If you want to use the method capturePhotoAsSampleBufferWithCompletionHandler:, you must comment out the line in GPUImageStillCamera.m in the method initWithSessionPreset:cameraPosition: which sets the CVPixelBufferPixelFormatTypeKey, as well as uncomment the rest of the method capturePhotoAsSampleBufferWithCompletionHandler:. However, if you do this you cannot use any of the photo capture methods to take a photo if you also supply a filter.");
    
    /*dispatch_semaphore_wait(frameRenderingSemaphore, DISPATCH_TIME_FOREVER);
    
    [photoOutput captureStillImageAsynchronouslyFromConnection:[[photoOutput connections] objectAtIndex:0] completionHandler:^(CMSampleBufferRef imageSampleBuffer, NSError *error) {
        block(imageSampleBuffer, error);
    }];
     
     dispatch_semaphore_signal(frameRenderingSemaphore);

     */
    
    return;
}

- (void)capturePhotoAsImageProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain withCompletionHandler:(void (^)(UIImage *processedImage, NSError *error))block;
{
    [self capturePhotoProcessedUpToFilter:finalFilterInChain withImageOnGPUHandler:^(NSError *error) {
        UIImage *filteredPhoto = nil;

        if(!error){
            filteredPhoto = [finalFilterInChain imageFromCurrentFramebuffer];
        }
        dispatch_semaphore_signal(frameRenderingSemaphore);

        block(filteredPhoto, error);
    }];
}

- (void)capturePhotoAsImageProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain withOrientation:(UIImageOrientation)orientation withCompletionHandler:(void (^)(UIImage *processedImage, NSError *error))block {
    [self capturePhotoProcessedUpToFilter:finalFilterInChain withImageOnGPUHandler:^(NSError *error) {
        UIImage *filteredPhoto = nil;
        
        if(!error) {
            filteredPhoto = [finalFilterInChain imageFromCurrentFramebufferWithOrientation:orientation];
        }
        dispatch_semaphore_signal(frameRenderingSemaphore);
        
        block(filteredPhoto, error);
    }];
}

- (void)capturePhotoAsJPEGProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain withCompletionHandler:(void (^)(NSData *processedJPEG, NSError *error))block;
{
//    reportAvailableMemoryForGPUImage(@"Before Capture");

    [self capturePhotoProcessedUpToFilter:finalFilterInChain withImageOnGPUHandler:^(NSError *error) {
        NSData *dataForJPEGFile = nil;

        if(!error){
            @autoreleasepool {
                UIImage *filteredPhoto = [finalFilterInChain imageFromCurrentFramebuffer];
                dispatch_semaphore_signal(frameRenderingSemaphore);
//                reportAvailableMemoryForGPUImage(@"After UIImage generation");

                dataForJPEGFile = UIImageJPEGRepresentation(filteredPhoto,self.jpegCompressionQuality);
//                reportAvailableMemoryForGPUImage(@"After JPEG generation");
            }

//            reportAvailableMemoryForGPUImage(@"After autorelease pool");
        }else{
            dispatch_semaphore_signal(frameRenderingSemaphore);
        }

        block(dataForJPEGFile, error);
    }];
}

- (void)capturePhotoAsJPEGProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain withOrientation:(UIImageOrientation)orientation withCompletionHandler:(void (^)(NSData *processedImage, NSError *error))block {
    [self capturePhotoProcessedUpToFilter:finalFilterInChain withImageOnGPUHandler:^(NSError *error) {
        NSData *dataForJPEGFile = nil;
        
        if(!error) {
            @autoreleasepool {
                UIImage *filteredPhoto = [finalFilterInChain imageFromCurrentFramebufferWithOrientation:orientation];
                dispatch_semaphore_signal(frameRenderingSemaphore);
                
                dataForJPEGFile = UIImageJPEGRepresentation(filteredPhoto, self.jpegCompressionQuality);
            }
        } else {
            dispatch_semaphore_signal(frameRenderingSemaphore);
        }
        
        block(dataForJPEGFile, error);
    }];
}

- (void)capturePhotoAsPNGProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain withCompletionHandler:(void (^)(NSData *processedPNG, NSError *error))block;
{

    [self capturePhotoProcessedUpToFilter:finalFilterInChain withImageOnGPUHandler:^(NSError *error) {
        NSData *dataForPNGFile = nil;

        if(!error){
            @autoreleasepool {
                UIImage *filteredPhoto = [finalFilterInChain imageFromCurrentFramebuffer];
                dispatch_semaphore_signal(frameRenderingSemaphore);
                dataForPNGFile = UIImagePNGRepresentation(filteredPhoto);
            }
        }else{
            dispatch_semaphore_signal(frameRenderingSemaphore);
        }
        
        block(dataForPNGFile, error);        
    }];
    
    return;
}

- (void)capturePhotoAsPNGProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain withOrientation:(UIImageOrientation)orientation withCompletionHandler:(void (^)(NSData *processedPNG, NSError *error))block;
{
    
    [self capturePhotoProcessedUpToFilter:finalFilterInChain withImageOnGPUHandler:^(NSError *error) {
        NSData *dataForPNGFile = nil;
        
        if(!error){
            @autoreleasepool {
                UIImage *filteredPhoto = [finalFilterInChain imageFromCurrentFramebufferWithOrientation:orientation];
                dispatch_semaphore_signal(frameRenderingSemaphore);
                dataForPNGFile = UIImagePNGRepresentation(filteredPhoto);
            }
        }else{
            dispatch_semaphore_signal(frameRenderingSemaphore);
        }
        
        block(dataForPNGFile, error);
    }];
    
    return;
}

#pragma mark - Private Methods

- (void)capturePhotoProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain withImageOnGPUHandler:(void (^)(NSError *error))block
{
    dispatch_semaphore_wait(frameRenderingSemaphore, DISPATCH_TIME_FOREVER);
    // it is illegal to use the same settings for two photos, so create new before each capture
    AVCapturePhotoSettings *settings = [self createPhotoSettings];
    self.currentCaptureInfo = [[GPUImageStillCaptureInfo alloc] initWithFinalFilter:finalFilterInChain handler:block];
    [photoOutput capturePhotoWithSettings:settings delegate:self];
}

#pragma mark - AVCapturePhotoCaptureDelegate

- (void)captureOutput:(AVCapturePhotoOutput *)output
didFinishProcessingPhoto:(AVCapturePhoto *)photo
                error:(NSError *)error {
    
    if (error != nil) {
        self.currentCaptureInfo.handler(error);
        return;
    }
    else if (photo.pixelBuffer == nil) {
        NSError *error = [[NSError alloc] initWithDomain:NSStringFromClass(self.class) code:0 userInfo:@{ NSLocalizedDescriptionKey: @"AVCapturePhotoOutput.pixelBuffer was nil" }];
        self.currentCaptureInfo.handler(error);
        return;
    }
    
    CMTime frameTime = CMTimeMake(1, 30);
    CMSampleTimingInfo timing = {frameTime, frameTime, kCMTimeInvalid};
    
//    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixel_buffer, YES, NULL, NULL, videoInfo, &timing, sampleBuffer);
    
    CMSampleBufferRef imageSampleBuffer = nil;
    
    CMVideoFormatDescriptionRef videoInfo = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(NULL, photo.pixelBuffer, &videoInfo);
    
    CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,
                                             photo.pixelBuffer,
                                             videoInfo,
                                             &timing,
                                             &imageSampleBuffer);
    
    if(imageSampleBuffer == NULL){
        self.currentCaptureInfo.handler(error);
        return;
    }

    // For now, resize photos to fix within the max texture size of the GPU
    CVImageBufferRef cameraFrame = CMSampleBufferGetImageBuffer(imageSampleBuffer);
    
    CGSize sizeOfPhoto = CGSizeMake(CVPixelBufferGetWidth(cameraFrame), CVPixelBufferGetHeight(cameraFrame));
    CGSize scaledImageSizeToFitOnGPU = [GPUImageContext sizeThatFitsWithinATextureForSize:sizeOfPhoto];
    if (!CGSizeEqualToSize(sizeOfPhoto, scaledImageSizeToFitOnGPU))
    {
        CMSampleBufferRef sampleBuffer = NULL;
        
        if (CVPixelBufferGetPlaneCount(cameraFrame) > 0)
        {
            NSAssert(NO, @"Error: no downsampling for YUV input in the framework yet");
        }
        else
        {
            GPUImageCreateResizedSampleBuffer(cameraFrame, scaledImageSizeToFitOnGPU, &sampleBuffer);
        }

        dispatch_semaphore_signal(frameRenderingSemaphore);
        [self.currentCaptureInfo.finalFilterInChain useNextFrameForImageCapture];
        [self captureOutput:photoOutput didOutputSampleBuffer:sampleBuffer fromConnection:[[photoOutput connections] objectAtIndex:0]];
        dispatch_semaphore_wait(frameRenderingSemaphore, DISPATCH_TIME_FOREVER);
        if (sampleBuffer != NULL)
            CFRelease(sampleBuffer);
    }
    else
    {
        // This is a workaround for the corrupt images that are sometimes returned when taking a photo with the front camera and using the iOS 5.0 texture caches
        AVCaptureDevicePosition currentCameraPosition = [[videoInput device] position];
        if ( (currentCameraPosition != AVCaptureDevicePositionFront) || (![GPUImageContext supportsFastTextureUpload]) || !requiresFrontCameraTextureCacheCorruptionWorkaround)
        {
            dispatch_semaphore_signal(frameRenderingSemaphore);
            [self.currentCaptureInfo.finalFilterInChain useNextFrameForImageCapture];
            [self captureOutput:photoOutput didOutputSampleBuffer:imageSampleBuffer fromConnection:[[photoOutput connections] objectAtIndex:0]];
            dispatch_semaphore_wait(frameRenderingSemaphore, DISPATCH_TIME_FOREVER);
        }
    }
    
    CFDictionaryRef metadata = CMCopyDictionaryOfAttachments(NULL, imageSampleBuffer, kCMAttachmentMode_ShouldPropagate);
    _currentCaptureMetadata = (__bridge_transfer NSDictionary *)metadata;

    self.currentCaptureInfo.handler(nil);

    _currentCaptureMetadata = nil;
}

- (AVCapturePhotoSettings *) createPhotoSettings {
    AVCapturePhotoSettings *photoCaptureSettings = [AVCapturePhotoSettings photoSettingsWithFormat:self.photoSettingsFormat];
    photoCaptureSettings.flashMode = self.flashMode ? AVCaptureFlashModeOn : AVCaptureFlashModeOff;
    photoCaptureSettings.highResolutionPhotoEnabled = YES;
    return photoCaptureSettings;
}

@end
