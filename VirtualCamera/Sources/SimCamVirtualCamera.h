#import <Foundation/Foundation.h>

/// Installs the full virtual-camera capture-graph mock: fabricated
/// `AVCaptureDevice` discovery, a dummy `AVCaptureDeviceInput` that never
/// touches the private FigCaptureSource, session add-input/output +
/// startRunning interception, and `CMSampleBuffer` delivery to the app's
/// `AVCaptureVideoDataOutput` sample-buffer delegate — all fed from the
/// shared `/tmp/SimCam.bgra` buffer. Public AVFoundation APIs only.
void SimCamInstallVirtualCamera(void);
