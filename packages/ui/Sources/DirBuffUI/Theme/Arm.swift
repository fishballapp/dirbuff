import SwiftUI

/// The flexed arm of the 💪 mark, drawn from the brand's outline on a 100 × 100 grid and scaled to
/// fit the rect it's given, centred.
public struct Arm: Shape {
  public init() {}

  public func path(in rect: CGRect) -> Path {
    let scale = min(rect.width, rect.height) / 100
    let origin = CGPoint(
      x: rect.midX - 50 * scale,
      y: rect.midY - 50 * scale)
    return Self.outline.applying(
      CGAffineTransform(translationX: origin.x, y: origin.y).scaledBy(x: scale, y: scale))
  }

  /// The outline, parsed once. It uses absolute M, L, C and Z only, with repeated coordinate
  /// pairs continuing the previous command, as the brand file has it.
  private static let outline: Path = {
    let tokens = pathData.split(separator: " ")
    var index = 0
    func number() -> CGFloat {
      defer { index += 1 }
      return CGFloat(Double(tokens[index]) ?? 0)
    }
    func point() -> CGPoint { CGPoint(x: number(), y: number()) }
    var path = Path()
    var command: Substring = ""
    while index < tokens.count {
      if let first = tokens[index].first, first.isLetter {
        command = tokens[index]
        index += 1
      }
      switch command {
      case "M":
        path.move(to: point())
        command = "L"
      case "L":
        path.addLine(to: point())
      case "C":
        let control1 = point()
        let control2 = point()
        path.addCurve(to: point(), control1: control1, control2: control2)
      default:
        path.closeSubpath()
      }
    }
    return path
  }()

  private static let pathData =
    "M 44.04 0.31 C 42.86 0.65 42.07 1.35 41.18 2.89 C 38.71 7.12 38.31 7.67 35.51 10.64 C "
    + "34.39 11.82 33.63 12.82 33.26 13.58 C 32.37 15.39 33.01 17.5 34.81 18.71 C 35.11 18.91 "
    + "35.37 19.09 35.39 19.1 C 35.41 19.12 35.27 19.32 35.08 19.55 C 34.5 20.23 34.14 20.77 "
    + "33.85 21.38 C 33.1 22.94 33.76 24.8 35.32 25.58 C 36.61 26.22 37.85 26.21 40.62 25.55 C "
    + "43.13 24.94 43.2 24.95 45.81 25.8 C 49.08 26.86 50.4 27.1 52.51 27.02 C 54.63 26.94 56.06 "
    + "26.52 58.8 25.18 C 61.8 23.71 62.22 23.97 63.99 28.39 C 65.25 31.52 66.31 35.03 66.94 "
    + "38.14 C 67.96 43.15 68.11 46.41 67.56 51.98 C 66.77 60.07 67.37 64.44 69.77 67.97 C 70.09 "
    + "68.44 70.32 68.82 70.3 68.82 C 70.13 68.82 69.06 68.21 68.54 67.83 C 67.8 67.27 66.7 66.11 "
    + "65.99 65.13 C 63.21 61.29 61.71 59.74 59.03 57.96 C 53.12 54.03 43.93 51.86 37.65 52.92 C "
    + "34.59 53.43 31.07 54.67 28.26 56.23 C 24.09 58.54 21.02 61.4 17.33 66.4 C 16.42 67.62 "
    + "16.47 67.57 15.29 68.28 C 13.85 69.13 11.56 70.22 9.53 71.01 C 7.1 71.95 5.35 72.66 4.86 "
    + "72.91 C 3.15 73.78 1.68 75.21 0.38 77.28 L 0 77.87 0 88.94 L 0 100 4.11 100 C 8.78 100 "
    + "10.47 99.92 12.27 99.6 C 15.87 98.96 18.55 97.63 23.98 93.8 L 24.63 93.33 25.68 93.74 C "
    + "29.95 95.39 35.21 96.79 39.6 97.44 C 44.46 98.16 53.04 98.21 59.53 97.57 C 62.73 97.26 "
    + "67.84 96.41 71.16 95.64 C 71.93 95.46 72.82 95.26 73.15 95.19 C 76.98 94.36 85.36 91.74 "
    + "90.21 89.85 C 90.58 89.7 91.69 89.28 92.68 88.92 C 96.08 87.66 97.65 86.67 98.66 85.11 C "
    + "99.71 83.52 99.89 81.91 99.33 79.2 C 98.88 76.98 98.85 76.19 99.15 74.21 C 100 68.69 99.05 "
    + "60.8 96.8 54.54 C 95.92 52.09 93.64 47.23 92.08 44.47 C 91.76 43.9 91.27 43.02 90.99 42.5 "
    + "C 90.7 41.98 90.34 41.33 90.18 41.06 C 90.01 40.79 89.42 39.78 88.86 38.81 C 87.97 37.27 "
    + "87.28 36.09 85.61 33.24 C 82.09 27.23 79.48 21.96 78.2 18.28 C 77.31 15.72 76.15 14.19 "
    + "73.66 12.33 C 72.44 11.41 71.49 10.78 68.87 9.12 C 65.11 6.73 60.94 4.91 56.2 3.58 C 51.63 "
    + "2.3 50.77 2.03 49.02 1.3 C 46.57 0.28 45.15 0 44.04 0.31 Z "
}
