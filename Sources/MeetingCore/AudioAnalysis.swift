import Foundation

public enum AudioAnalysis {
  public static let sampleRate = 16_000
  public static func features(_ samples: [Float]) -> AcousticFeatures {
    guard !samples.isEmpty else {
      return AcousticFeatures(
        rmsDB: -100, peakDB: -100, silenceRatio: 1, longestPause: 0, pitchChangeHz: nil)
    }
    var sum: Double = 0
    var peak: Double = 0
    for sample in samples {
      let value = Double(sample)
      sum += value * value
      peak = max(peak, abs(value))
    }
    let frame = 1600
    var silent = 0
    var longest = 0
    var current = 0
    var count = 0
    for start in stride(from: 0, to: samples.count, by: frame) {
      let end = min(start + frame, samples.count)
      let energy = samples[start..<end].reduce(0.0) { $0 + Double($1 * $1) } / Double(end - start)
      count += 1
      if energy < 0.00001 {
        silent += 1
        current += 1
        longest = max(longest, current)
      } else {
        current = 0
      }
    }
    let first = pitch(Array(samples.prefix(8000)))
    let last = pitch(Array(samples.suffix(8000)))
    return AcousticFeatures(
      rmsDB: 10 * log10(max(1e-10, sum / Double(samples.count))),
      peakDB: 20 * log10(max(1e-5, peak)), silenceRatio: Double(silent) / Double(max(1, count)),
      longestPause: Double(longest) * 0.1, pitchChangeHz: first.flatMap { a in last.map { $0 - a } }
    )
  }

  // Autocorrelation of short voiced windows. Describes acoustics, never infers emotions.
  private static func pitch(_ samples: [Float]) -> Double? {
    guard samples.count >= 800 else { return nil }
    var estimates: [Double] = []
    for start in stride(from: 0, through: samples.count - 800, by: 800) {
      let energy = samples[start..<(start + 600)].reduce(0.0) { $0 + Double($1 * $1) }
      guard energy > 0.03 else { continue }
      var best = 0.0
      var lag = 0
      for shift in 40...200 {
        var cross = 0.0
        var shifted = 0.0
        for i in 0..<600 {
          let a = Double(samples[start + i])
          let b = Double(samples[start + i + shift])
          cross += a * b
          shifted += b * b
        }
        let correlation = cross / sqrt(max(1e-12, energy * shifted))
        if correlation > best {
          best = correlation
          lag = shift
        }
      }
      if best > 0.7 { estimates.append(16_000 / Double(lag)) }
    }
    return estimates.sorted().dropFirst(estimates.count / 2).first
  }

  public static func pcm16(_ samples: [Float]) -> Data {
    var values = samples.map {
      Int16((max(-1, min(1, $0.isFinite ? $0 : 0)) * 32767).rounded()).littleEndian
    }
    return values.withUnsafeMutableBytes { Data($0) }
  }
  public static func floats(_ data: Data) -> [Float] {
    stride(from: 0, to: data.count - data.count % 2, by: 2).map {
      let bits = UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8
      return Float(Int16(bitPattern: bits)) / 32768
    }
  }
  public static func wave(pcm: Data) -> Data {
    var data = Data()
    func word<T: FixedWidthInteger>(_ value: T) {
      var v = value.littleEndian
      withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: "RIFF".utf8)
    word(UInt32(36 + pcm.count))
    data.append(contentsOf: "WAVEfmt ".utf8)
    word(UInt32(16))
    word(UInt16(1))
    word(UInt16(1))
    word(UInt32(sampleRate))
    word(UInt32(sampleRate * 2))
    word(UInt16(2))
    word(UInt16(16))
    data.append(contentsOf: "data".utf8)
    word(UInt32(pcm.count))
    data.append(pcm)
    return data
  }
}
