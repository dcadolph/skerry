#if os(iOS)
    import SwiftUI
    import UIKit

    /// CameraPicker wraps the system camera so a captured photo can become note text. It falls back
    /// to the photo library when no camera is available, as in the simulator.
    struct CameraPicker: UIViewControllerRepresentable {
        /// Called with the captured image encoded as JPEG data.
        let onCapture: (Data) -> Void
        /// Dismisses the picker.
        @Environment(\.dismiss) private var dismiss

        func makeUIViewController(context: Context) -> UIImagePickerController {
            let picker = UIImagePickerController()
            picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera)
                ? .camera : .photoLibrary
            picker.delegate = context.coordinator
            return picker
        }

        func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        /// Coordinator bridges the picker's delegate callbacks to the SwiftUI closure.
        final class Coordinator: NSObject, UIImagePickerControllerDelegate,
            UINavigationControllerDelegate {
            /// The picker this coordinator serves.
            let parent: CameraPicker

            /// Creates a coordinator for a picker.
            init(_ parent: CameraPicker) { self.parent = parent }

            func imagePickerController(
                _ picker: UIImagePickerController,
                didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
            ) {
                if let image = info[.originalImage] as? UIImage,
                    let data = image.jpegData(compressionQuality: 0.9) {
                    parent.onCapture(data)
                }
                parent.dismiss()
            }

            func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
                parent.dismiss()
            }
        }
    }
#endif
