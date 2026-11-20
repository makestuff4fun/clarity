import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

// int __android_log_write(int prio, const char* tag, const char* text)
typedef _LogWriteC = Int32 Function(Int32, Pointer<Uint8>, Pointer<Uint8>);
typedef _LogWrite = int Function(int, Pointer<Uint8>, Pointer<Uint8>);
typedef _MallocC = Pointer<Uint8> Function(IntPtr);
typedef _Malloc = Pointer<Uint8> Function(int);
typedef _FreeC = Void Function(Pointer<Uint8>);
typedef _Free = void Function(Pointer<Uint8>);

const int _androidLogError = 6; // ANDROID_LOG_ERROR
// logcat truncates an entry at about 4 KB: send a long stack in pieces.
const int _chunkBytes = 3000;

_LogWrite? _logWrite;
_Malloc? _malloc;
_Free? _free;
bool _loaded = false;

bool _load() {
  if (_loaded) return _logWrite != null;
  _loaded = true;
  final log = DynamicLibrary.open('liblog.so');
  final libc = DynamicLibrary.open('libc.so');
  _logWrite = log.lookupFunction<_LogWriteC, _LogWrite>('__android_log_write');
  _malloc = libc.lookupFunction<_MallocC, _Malloc>('malloc');
  _free = libc.lookupFunction<_FreeC, _Free>('free');
  return true;
}

Pointer<Uint8> _cString(List<int> bytes) {
  final p = _malloc!(bytes.length + 1);
  final view = p.asTypedList(bytes.length + 1);
  view.setAll(0, bytes);
  view[bytes.length] = 0;
  return p;
}

/// Writes [message] to logcat at error priority under [tag]. A no-op off Android.
void logcatError(String tag, String message) {
  if (!Platform.isAndroid || !_load()) return;
  final tagC = _cString(utf8.encode(tag));
  try {
    final bytes = utf8.encode(message.replaceAll('\u0000', ''));
    for (int start = 0; start < bytes.length || start == 0; start += _chunkBytes) {
      final end = (start + _chunkBytes < bytes.length) ? start + _chunkBytes : bytes.length;
      // a chunk may split a multi-byte character; logcat shows a replacement mark, nothing worse
      final textC = _cString(bytes.sublist(start, end));
      try {
        _logWrite!(_androidLogError, tagC, textC);
      } finally {
        _free!(textC);
      }
      if (bytes.isEmpty) break;
    }
  } finally {
    _free!(tagC);
  }
}
