#if os(iOS)

    import PencilKit
    import SwiftUI

    /// SketchView is a full-screen PencilKit canvas; the finished drawing lands in the note
    /// as a PNG attachment, sealed like any image when the note is encrypted.
    struct SketchView: View {
        /// Receives the finished sketch as PNG data.
        let onSave: (Data) -> Void
        /// Dismisses the sheet.
        @Environment(\.dismiss) private var dismiss
        /// The shared canvas the representable manages.
        @State private var canvas = PKCanvasView()

        var body: some View {
            NavigationStack {
                SketchCanvas(canvas: canvas)
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Sketch")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { dismiss() }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Add") {
                                if let data = renderPNG() { onSave(data) }
                                dismiss()
                            }
                        }
                    }
            }
        }

        /// Renders the drawing to PNG over its own bounds, with padding, in the canvas's
        /// current appearance so ink colors bake in correctly.
        private func renderPNG() -> Data? {
            let drawing = canvas.drawing
            guard !drawing.strokes.isEmpty else { return nil }
            let rect = drawing.bounds.insetBy(dx: -16, dy: -16)
            var image = UIImage()
            canvas.traitCollection.performAsCurrent {
                image = drawing.image(from: rect, scale: 2)
            }
            return image.pngData()
        }
    }

    /// SketchCanvas hosts the PencilKit canvas and its tool picker.
    private struct SketchCanvas: UIViewRepresentable {
        /// Canvas owned by the sheet so the finished drawing can be read on save.
        let canvas: PKCanvasView

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        func makeUIView(context: Context) -> PKCanvasView {
            canvas.drawingPolicy = .anyInput
            canvas.backgroundColor = .systemBackground
            let picker = context.coordinator.toolPicker
            picker.setVisible(true, forFirstResponder: canvas)
            picker.addObserver(canvas)
            DispatchQueue.main.async {
                canvas.becomeFirstResponder()
            }
            return canvas
        }

        func updateUIView(_ view: PKCanvasView, context: Context) {}

        /// Coordinator retains the tool picker for the canvas's lifetime.
        final class Coordinator {
            /// Tool picker shown alongside the canvas.
            let toolPicker = PKToolPicker()
        }
    }

#endif
