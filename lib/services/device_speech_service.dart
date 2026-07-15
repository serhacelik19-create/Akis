import 'dart:io';

import 'package:flutter/services.dart';

class DeviceSpeechService {
  const DeviceSpeechService._();

  static const _channel = MethodChannel('akis/audio_capture');

  static Future<String> transcribe(File audioFile) async {
    try {
      final text = await _channel
          .invokeMethod<String>('transcribe', {'path': audioFile.path})
          .timeout(
            const Duration(seconds: 35),
            onTimeout: () => throw const DeviceSpeechException(
              'Konuşma tanıma zaman aşımına uğradı. Lütfen tekrar dene.',
            ),
          );
      if (text == null || text.trim().isEmpty) {
        throw const DeviceSpeechException('Konuşmadan metin çıkarılamadı.');
      }
      return text.trim();
    } on PlatformException catch (error) {
      throw DeviceSpeechException(
        error.message ?? 'Cihazın konuşma tanıması kullanılamıyor.',
      );
    }
  }
}

class DeviceSpeechException implements Exception {
  const DeviceSpeechException(this.message);
  final String message;
}
