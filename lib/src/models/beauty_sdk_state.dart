/// SDK lifecycle states.
enum BeautySDKState {
  /// SDK has not been initialized
  uninitialized,

  /// SDK is initializing (auth + GPU pipeline + model loading)
  initializing,

  /// SDK is ready to process frames
  ready,

  /// SDK is actively processing frames
  processing,

  /// SDK is paused (e.g., app in background)
  paused,

  /// SDK has been disposed
  disposed,
}
