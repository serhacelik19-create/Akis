import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Captures mono 16 kHz WAV without relying on macOS file-output callbacks.
///
/// The `record` macOS file recorder waits for an AVFoundation completion
/// callback that can fail to arrive. PCM streaming stops synchronously; Akış
/// writes the small WAV container itself after the stream has ended.
class AudioCaptureService {
  AudioCaptureService() : _recorder = AudioRecorder();

  static const _sampleRate = 16000;
  static const _channels = 1;
  static const _bytesPerSample = 2;
  static const _nativeChannel = MethodChannel('akis/audio_capture');

  final AudioRecorder _recorder;
  BytesBuilder _pcm = BytesBuilder(copy: false);
  StreamSubscription<Uint8List>? _streamSubscription;
  String? _activePath;
  Object? _streamError;
  bool _usesNativeMacCapture = false;

  Future<void> start() async {
    if (Platform.isMacOS) {
      await _invokeNative('start');
      _usesNativeMacCapture = true;
      return;
    }
    if (!await _recorder.hasPermission()) {
      throw const AudioCaptureException('Mikrofon izni verilmedi.');
    }

    final directory = await getTemporaryDirectory();
    _activePath =
        '${directory.path}/akis-${DateTime.now().millisecondsSinceEpoch}.wav';
    _pcm = BytesBuilder(copy: false);
    _streamError = null;

    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _sampleRate,
        numChannels: _channels,
      ),
    );
    _streamSubscription = stream.listen(
      _pcm.add,
      onError: (Object error, StackTrace stackTrace) => _streamError = error,
    );
  }

  Future<File?> stop() async {
    if (_usesNativeMacCapture) {
      try {
        final path = await _nativeChannel
            .invokeMethod<String>('stop')
            .timeout(const Duration(seconds: 8));
        if (path == null) return null;
        final file = File(path);
        return await file.exists() ? file : null;
      } on TimeoutException {
        throw const AudioCaptureException(
          'Ses kaydı kapatılamadı. Lütfen tekrar dene.',
        );
      } on PlatformException catch (error) {
        throw AudioCaptureException(error.message ?? 'Ses kaydı alınamadı.');
      } finally {
        _usesNativeMacCapture = false;
      }
    }
    final path = _activePath;
    if (path == null) return null;

    try {
      await _recorder.stop().timeout(const Duration(seconds: 4));
      // Native audio callbacks already queued on the Flutter event loop must
      // be consumed before the subscription is closed.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await _streamSubscription?.cancel();
      _streamSubscription = null;

      if (_streamError != null) {
        throw AudioCaptureException('Mikrofon akışı okunamadı: $_streamError');
      }
      final pcm = _pcm.takeBytes();
      if (pcm.isEmpty) {
        throw const AudioCaptureException('Ses kaydı boş geldi. Tekrar dene.');
      }

      final file = File(path);
      await file.writeAsBytes(_asWav(pcm), flush: true);
      return file;
    } on TimeoutException {
      throw const AudioCaptureException(
        'Ses kaydı kapatılamadı. Lütfen tekrar dene.',
      );
    } finally {
      _activePath = null;
    }
  }

  Future<void> cancel() async {
    if (_usesNativeMacCapture) {
      try {
        await _nativeChannel.invokeMethod<void>('cancel');
      } on PlatformException {
        // The native recorder may already have stopped.
      }
      _usesNativeMacCapture = false;
      return;
    }
    try {
      await _recorder.cancel().timeout(const Duration(seconds: 2));
    } catch (_) {
      // The native recorder may already have stopped.
    }
    await _streamSubscription?.cancel();
    _streamSubscription = null;
    _pcm = BytesBuilder(copy: false);
    _activePath = null;
  }

  Uint8List _asWav(Uint8List pcm) {
    final header = ByteData(44)
      ..setUint32(0, 0x52494646, Endian.big) // RIFF
      ..setUint32(4, 36 + pcm.length, Endian.little)
      ..setUint32(8, 0x57415645, Endian.big) // WAVE
      ..setUint32(12, 0x666d7420, Endian.big) // fmt
      ..setUint32(16, 16, Endian.little)
      ..setUint16(20, 1, Endian.little) // PCM
      ..setUint16(22, _channels, Endian.little)
      ..setUint32(24, _sampleRate, Endian.little)
      ..setUint32(28, _sampleRate * _channels * _bytesPerSample, Endian.little)
      ..setUint16(32, _channels * _bytesPerSample, Endian.little)
      ..setUint16(34, _bytesPerSample * 8, Endian.little)
      ..setUint32(36, 0x64617461, Endian.big) // data
      ..setUint32(40, pcm.length, Endian.little);
    return Uint8List.fromList([...header.buffer.asUint8List(), ...pcm]);
  }

  void dispose() {
    if (_usesNativeMacCapture) unawaited(cancel());
    final subscription = _streamSubscription;
    if (subscription != null) unawaited(subscription.cancel());
    unawaited(_recorder.dispose());
  }

  Future<void> _invokeNative(String method) async {
    try {
      await _nativeChannel.invokeMethod<void>(method);
    } on PlatformException catch (error) {
      throw AudioCaptureException(error.message ?? 'Mikrofon başlatılamadı.');
    }
  }
}

class AudioCaptureException implements Exception {
  const AudioCaptureException(this.message);
  final String message;
}
