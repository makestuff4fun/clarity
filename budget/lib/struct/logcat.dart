// Writes straight to Android's logcat (liblog), bypassing Dart's print, which captureLogs's zone
// intercepts and which is not a dependable route out of a release build. See startupGuard.dart.
export 'logcat_stub.dart' if (dart.library.ffi) 'logcat_ffi.dart';
