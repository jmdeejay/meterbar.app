import SwiftUI

/// Shared between the main app and the widget extension via the
/// `PBXFileSystemSynchronizedBuildFileExceptionSet` membership-exception list
/// in `project.pbxproj` (same pattern `Services/SharedDataStore.swift` uses).
///
/// Single source of truth for every rectangle-backed progress bar in the UI.
/// Sized via GeometryReader so the fill is a fraction of the rendered width;
/// height and horizontal padding are parameterised for the four contexts:
///
/// - **Popover expanded rows** use the default (`height: 8`, no padding) to
///   match the system `ProgressView` linear style without inheriting its
///   focus-fade.
/// - **Popover collapsed headers** use `height: 4, horizontalPadding: 8` so
///   the bar fills the gap between the service label and the trailing status
///   dot without crowding either.
/// - **Small widget rows** use `height: 4` for the tightest layout.
/// - **Medium/Large widget rows** use `height: 5` (column) or `height: 7`
///   (wide row) to match the surrounding type sizes.
struct UsageProgressBar: View {
    let percentage: Double
    let color: Color
    var height: CGFloat = 8
    var horizontalPadding: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.gray.opacity(0.3))
                Capsule()
                    .fill(color)
                    .frame(width: geo.size.width * CGFloat(min(max(percentage, 0), 100) / 100))
            }
        }
        .frame(height: height)
        .padding(.horizontal, horizontalPadding)
    }
}
