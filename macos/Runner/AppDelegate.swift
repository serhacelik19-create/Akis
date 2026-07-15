import Cocoa
import AVFoundation
import Speech
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private let audioChannelName = "akis/audio_capture"
  private let captureQueue = DispatchQueue(label: "com.akis.audio.capture")
  private var audioEngine: AVAudioEngine?
  private var converter: AVAudioConverter?
  private var outputFormat: AVAudioFormat?
  private var pcmData = Data()
  private var recognitionTask: SFSpeechRecognitionTask?

  func configureAudioChannel(binaryMessenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: audioChannelName,
      binaryMessenger: binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handleAudioCall(call, result: result)
    }
  }

  private func handleAudioCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      startCapture(result: result)
    case "stop":
      stopCapture(result: result)
    case "cancel":
      cancelCapture()
      result(nil)
    case "transcribe":
      guard let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String else {
        result(FlutterError(code: "invalid_audio", message: "Ses dosyası bulunamadı.", details: nil))
        return
      }
      transcribeAudio(at: path, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func startCapture(result: @escaping FlutterResult) {
    let authorization = AVCaptureDevice.authorizationStatus(for: .audio)
    if authorization == .notDetermined {
      AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
        DispatchQueue.main.async {
          guard let self else { return }
          guard granted else {
            result(FlutterError(code: "microphone_denied", message: "Mikrofon izni verilmedi.", details: nil))
            return
          }
          self.beginCapture(result: result)
        }
      }
      return
    }
    guard authorization == .authorized else {
      result(FlutterError(code: "microphone_denied", message: "Mikrofon izni verilmedi.", details: nil))
      return
    }
    beginCapture(result: result)
  }

  private func beginCapture(result: @escaping FlutterResult) {
    cancelCapture()
    do {
      let engine = AVAudioEngine()
      let input = engine.inputNode
      let inputFormat = input.inputFormat(forBus: 0)
      guard inputFormat.sampleRate > 0 else {
        throw NSError(domain: "AkisAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mikrofon biçimi okunamadı."])
      }
      guard let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
      ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
        throw NSError(domain: "AkisAudio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Mikrofon sesi dönüştürülemedi."])
      }

      self.outputFormat = outputFormat
      self.converter = converter
      self.audioEngine = engine
      captureQueue.sync { pcmData.removeAll(keepingCapacity: true) }

      input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
        self?.append(buffer: buffer)
      }
      engine.prepare()
      try engine.start()
      result(nil)
    } catch {
      cancelCapture()
      result(FlutterError(code: "capture_start_failed", message: error.localizedDescription, details: nil))
    }
  }

  private func append(buffer: AVAudioPCMBuffer) {
    guard let converter, let outputFormat else { return }
    let ratio = outputFormat.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(max(1, Int(Double(buffer.frameLength) * ratio) + 1))
    guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
    var conversionError: NSError?
    converter.convert(to: output, error: &conversionError) { _, status in
      status.pointee = .haveData
      return buffer
    }
    guard conversionError == nil, let samples = output.int16ChannelData else { return }
    let byteCount = Int(output.frameLength) * MemoryLayout<Int16>.size
    guard byteCount > 0 else { return }
    let chunk = Data(bytes: samples[0], count: byteCount)
    captureQueue.async { [weak self] in self?.pcmData.append(chunk) }
  }

  private func stopCapture(result: @escaping FlutterResult) {
    guard let engine = audioEngine else {
      result(FlutterError(code: "not_recording", message: "Etkin bir ses kaydı yok.", details: nil))
      return
    }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    engine.reset()
    audioEngine = nil
    converter = nil
    outputFormat = nil

    let pcm = captureQueue.sync { () -> Data in
      let data = pcmData
      pcmData.removeAll(keepingCapacity: false)
      return data
    }
    guard !pcm.isEmpty else {
      result(FlutterError(code: "empty_recording", message: "Ses kaydı boş geldi.", details: nil))
      return
    }
    do {
      let directory = try FileManager.default.url(
        for: .cachesDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      let fileURL = directory.appendingPathComponent("akis-\(UUID().uuidString).wav")
      try wavData(from: pcm).write(to: fileURL, options: .atomic)
      result(fileURL.path)
    } catch {
      result(FlutterError(code: "wav_write_failed", message: error.localizedDescription, details: nil))
    }
  }

  private func cancelCapture() {
    audioEngine?.inputNode.removeTap(onBus: 0)
    audioEngine?.stop()
    audioEngine = nil
    converter = nil
    outputFormat = nil
    captureQueue.sync { pcmData.removeAll(keepingCapacity: false) }
  }

  private func transcribeAudio(at path: String, result: @escaping FlutterResult) {
    switch SFSpeechRecognizer.authorizationStatus() {
    case .authorized:
      beginTranscription(path: path, result: result)
    case .notDetermined:
      SFSpeechRecognizer.requestAuthorization { [weak self] status in
        DispatchQueue.main.async {
          guard let self else { return }
          guard status == .authorized else {
            result(FlutterError(code: "speech_denied", message: "Konuşma tanıma izni verilmedi.", details: nil))
            return
          }
          self.beginTranscription(path: path, result: result)
        }
      }
    default:
      result(FlutterError(code: "speech_denied", message: "Konuşma tanıma izni verilmedi.", details: nil))
    }
  }

  private func beginTranscription(path: String, result: @escaping FlutterResult) {
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "tr_TR")) else {
      result(FlutterError(code: "turkish_unavailable", message: "Bu cihazda Türkçe konuşma tanıma bulunamadı.", details: nil))
      return
    }
    guard recognizer.isAvailable else {
      result(FlutterError(code: "speech_unavailable", message: "Cihazın konuşma tanıması şu anda kullanılamıyor.", details: nil))
      return
    }
    guard recognizer.supportsOnDeviceRecognition else {
      result(FlutterError(code: "on_device_unavailable", message: "Türkçe cihaz içi konuşma paketi kurulu değil.", details: nil))
      return
    }

    recognitionTask?.cancel()
    let request = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: path))
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = false
    request.taskHint = .dictation
    var completed = false
    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] transcription, error in
      guard !completed else { return }
      if let transcription, transcription.isFinal {
        completed = true
        self?.recognitionTask = nil
        result(transcription.bestTranscription.formattedString)
      } else if let error {
        completed = true
        self?.recognitionTask = nil
        result(FlutterError(code: "transcription_failed", message: error.localizedDescription, details: nil))
      }
    }
  }

  private func wavData(from pcm: Data) -> Data {
    var wav = Data()
    wav.append(contentsOf: Array("RIFF".utf8))
    wav.appendLittleEndian(UInt32(36 + pcm.count))
    wav.append(contentsOf: Array("WAVEfmt ".utf8))
    wav.appendLittleEndian(UInt32(16))
    wav.appendLittleEndian(UInt16(1))
    wav.appendLittleEndian(UInt16(1))
    wav.appendLittleEndian(UInt32(16_000))
    wav.appendLittleEndian(UInt32(32_000))
    wav.appendLittleEndian(UInt16(2))
    wav.appendLittleEndian(UInt16(16))
    wav.append(contentsOf: Array("data".utf8))
    wav.appendLittleEndian(UInt32(pcm.count))
    wav.append(pcm)
    return wav
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

private extension Data {
  mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
    var littleEndian = value.littleEndian
    append(Data(bytes: &littleEndian, count: MemoryLayout<T>.size))
  }
}
