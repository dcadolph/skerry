#if os(iOS)

    import SwiftUI
    import VisionKit

    /// DocumentScanView wraps the system document camera; finished pages come back as
    /// images for OCR and PDF binding.
    struct DocumentScanView: UIViewControllerRepresentable {
        /// Receives the scanned pages.
        let onScan: ([UIImage]) -> Void
        /// Dismisses the sheet.
        @Environment(\.dismiss) private var dismiss

        func makeCoordinator() -> Coordinator {
            Coordinator(self)
        }

        func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
            let controller = VNDocumentCameraViewController()
            controller.delegate = context.coordinator
            return controller
        }

        func updateUIViewController(
            _ controller: VNDocumentCameraViewController, context: Context
        ) {}

        /// Coordinator relays the scan result and closes the sheet. The delegate protocol
        /// is nonisolated in the SDK; its callbacks arrive on the main thread, which is
        /// asserted before view state is touched.
        @MainActor
        final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
            /// Owning representable.
            private let parent: DocumentScanView

            /// Creates a coordinator for one representable.
            init(_ parent: DocumentScanView) {
                self.parent = parent
            }

            nonisolated func documentCameraViewController(
                _ controller: VNDocumentCameraViewController,
                didFinishWith scan: VNDocumentCameraScan
            ) {
                var pages: [UIImage] = []
                for index in 0..<scan.pageCount {
                    pages.append(scan.imageOfPage(at: index))
                }
                let finished = pages
                MainActor.assumeIsolated {
                    parent.onScan(finished)
                    parent.dismiss()
                }
            }

            nonisolated func documentCameraViewControllerDidCancel(
                _ controller: VNDocumentCameraViewController
            ) {
                MainActor.assumeIsolated {
                    parent.dismiss()
                }
            }

            nonisolated func documentCameraViewController(
                _ controller: VNDocumentCameraViewController, didFailWithError error: Error
            ) {
                MainActor.assumeIsolated {
                    parent.dismiss()
                }
            }
        }
    }

#endif
