# Image Merge Design

Date: 2026-05-29
Status: Draft for user review
Project: capcap

## Summary

Add an Image Merge feature for combining multiple images into one PNG through a dedicated AppKit workbench. The workbench supports template-based layout, light manual adjustment, direct copy/save output, and a path into the existing annotation editor for further editing.

The first version uses a separate `capcap/ImageMerge/` module instead of embedding this behavior inside the existing screenshot editor. The merge workbench owns multi-image layout and rendering; the editor continues to own annotation, beautify, upload, pin, and final screenshot-style editing workflows.

## Goals

- Start Image Merge from the menu bar and from a customizable global shortcut.
- When triggered by shortcut, import the current Finder image selection if at least two image files are selected.
- Let the menu entry open an empty merge workbench that can import images from file selection, clipboard, and drag-and-drop.
- Provide four first-version templates: horizontal row, vertical column, equal-width grid, and long-image stitch.
- Support manual adjustment after template layout: drag to reorder, select one image, move it within its template slot, and resize it proportionally.
- Support merge parameters for spacing, outer margin, transparent or solid background, background color, and image corner radius.
- Output the rendered merge as PNG through copy, save, or continue editing.
- Add copied merge outputs to History; do not add direct save outputs to History.
- Reuse the existing editor when the user chooses to continue editing.

## Non-Goals

- No freeform infinite canvas in the first version.
- No per-image crop tool, independent aspect-fill/fit mode, shadow, border, captions, or text overlays.
- No social-media canvas presets, fixed aspect ratios, or custom width/height controls.
- No additional collage templates beyond the four first-version templates.
- No upload or pin buttons directly in the merge workbench; those stay available through Continue Editing.
- No third-party dependencies and no SwiftUI.

## User Flow

The menu bar gains a new `Merge Images` item near the existing screenshot and record actions. It displays the configured shortcut when one is set. Clicking it opens an Image Merge workbench. If no images are loaded, the workbench shows an empty state that accepts drag-and-drop and offers file and clipboard import.

The global shortcut is added as a dedicated shortcut slot in Settings. When fired, capcap reads the current Finder selection. If two or more image files are selected, it opens the workbench with those images loaded in Finder order. If fewer than two image files are available, it shows a localized toast asking the user to select at least two images.

The workbench has three output actions:

- Copy: render the current merge, copy it to the clipboard, add it to History, and show the normal copied toast.
- Save: render the current merge and write a PNG to a user-selected file path. This does not add a History entry.
- Continue Editing: render the current merge and open it in the existing editor as an image-edit source. From there, annotation, beautify, upload, pin, save, and confirm/copy all follow the existing editor behavior.

Closing the workbench discards unsaved merge state.

## Workbench UI

The workbench is a standalone AppKit window. It contains a large preview canvas and a compact controls surface. The exact placement can follow AppKit constraints during implementation, but the visible controls must support these groups:

- Image sources: add files, add from clipboard, and drag-and-drop onto the window or empty state.
- Image list: thumbnails in current order, with drag-to-reorder.
- Template picker: horizontal, vertical, grid, and long stitch.
- Layout controls: spacing, outer margin, background mode, background color, and image corner radius.
- Output actions: copy, save, continue editing, and close.

When an image is selected, the preview shows selection chrome for that image. The user can drag the selected image to adjust its position inside its template slot and use a proportional resize affordance to scale it. These per-image adjustments are stored as offset and scale relative to the current template slot.

Switching templates preserves image order and shared layout parameters, but resets per-image offsets and scales. This avoids carrying position adjustments into a different slot geometry where they would become surprising.

Output actions are disabled until at least two valid images are loaded.

## Architecture

Add a focused `capcap/ImageMerge/` module with these units:

- `ImageMergeLauncher`: coordinates menu, shortcut, Finder selection, file selection, clipboard import, and workbench presentation.
- `ImageMergeWindowController`: owns the workbench window lifecycle, control wiring, import actions, output actions, and localized UI state.
- `ImageMergeCanvasView`: draws the preview, handles selection, drag-to-adjust, proportional scaling, and drag-and-drop import feedback.
- `ImageMergeDocument`: stores merge state, including images, template, spacing, margin, background, corner radius, selected item, and per-item adjustments.
- `ImageMergeRenderer`: computes template layout and renders the final `NSImage` from a document.

Keep the renderer free of AppKit window/controller state. Controllers should mutate the document, ask the renderer for layout or output, and then update the canvas. This keeps rendering testable and prevents merge-specific behavior from leaking into `EditWindowController` or `EditCanvasView`.

## Data Model

`ImageMergeDocument` should represent:

- `items`: ordered merge items, each with an id, source display name, decoded `NSImage`, original size, offset, and scale.
- `template`: one of horizontal, vertical, grid, or long stitch.
- `spacing`: point value between images or cells.
- `margin`: point value around the final canvas.
- `background`: transparent or solid color.
- `cornerRadius`: point value applied to every rendered image.
- `selectedItemID`: optional selected item.

The first version does not need persistent documents. Workbench state is in memory only.

## Rendering Rules

All first-version outputs are PNG. The renderer returns one final `NSImage`; copy, save, and continue editing all consume that same image so preview and output stay consistent.

Template behavior:

- Horizontal row: preserve each image's display size and place images left to right with spacing.
- Vertical column: preserve each image's display size and place images top to bottom with spacing.
- Equal-width grid: choose a column count close to a square grid for the current image count, scale each image proportionally to the common cell width, and compute row heights from the scaled images.
- Long-image stitch: scale all images to a common width and stack them vertically with spacing.

The canvas size is automatic. It is derived from the chosen template, image sizes, spacing, margin, and per-item scale/offset bounds. Transparent backgrounds preserve alpha. Solid backgrounds fill the full output canvas before images are drawn. Corner radius is applied while drawing each image and does not alter the stored source image.

The preview may scale the rendered layout down to fit the workbench window, but the exported PNG uses the document's full computed size.

## Integration Points

`StatusBarController` gets a new menu item for Image Merge. It should rebuild when language or hotkey state changes, matching the existing shortcut-display pattern.

`AppDelegate` gets a merge trigger path alongside screenshot, record, selected-image edit, and clipboard-image edit. It must avoid opening the workbench while a capture overlay, recording, countdown, or another merge workbench is already active.

`FinderSelection` already has multi-image selection support through `currentImageFileURLs()`. The shortcut path should require at least two images before launching.

`HotkeyManager` and `Defaults` get a new merge shortcut slot, display string helper, registration/unregistration, conflict detection, and reset behavior. The shortcut is not set by default.

`SettingsView` adds a `Merge Images` shortcut card in the Shortcuts tab. It should follow the existing shortcut-card behavior: set, cancel, restore, conflict alert, and display refresh.

`Resources/*.lproj/Localizable.strings` get strings for menu title, settings labels, empty state, import actions, output actions, and error toasts.

## Error Handling

- If Finder shortcut launch finds fewer than two images, show a toast asking the user to select at least two images.
- If one or more imported files cannot be decoded, skip those files and show a toast indicating that some images could not be loaded.
- Dragged non-image files are ignored.
- Clipboard import shows a toast when the clipboard has no image.
- Output actions remain disabled with fewer than two valid images.
- If final rendering fails, show a localized merge-failed toast and leave the workbench open.

## Verification Plan

After implementation code changes, run:

```bash
bash scripts/compile-check.sh
```

Because this is runtime-sensitive UI work, also run:

```bash
bash scripts/rebuild-and-open.sh
```

Manual verification should cover:

- Menu item opens an empty workbench.
- Menu item displays the configured shortcut.
- Merge shortcut opens Finder-selected multi-image input.
- Merge shortcut shows the expected toast with fewer than two images.
- File picker imports multiple images.
- Clipboard import works and shows the empty-clipboard toast when needed.
- Drag-and-drop imports images and ignores non-images.
- Horizontal, vertical, grid, and long stitch templates render correctly.
- Reordering updates layout.
- Per-image move and proportional scale affect preview and output.
- Spacing, margin, transparent background, solid background color, and image corner radius affect preview and output.
- Copy writes PNG data to the clipboard and adds a History entry.
- Save writes a PNG and does not add a History entry.
- Continue Editing opens the existing editor with the merged image.
- Existing screenshot, record, image edit, clipboard edit, upload, pin, and History flows still behave normally.

