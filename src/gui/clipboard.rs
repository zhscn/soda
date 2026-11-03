//! The window system's own clipboard: on Wayland through the window's
//! connection, elsewhere (X11, macOS) through arboard. Without either the
//! clipboard tools still serve, as in the terminal.
use crate::runtime::SystemClipboard;
use winit::{
    raw_window_handle::{HasDisplayHandle, RawDisplayHandle},
    window::Window,
};

enum Native {
    #[cfg(all(unix, not(target_os = "macos")))]
    Wayland(smithay_clipboard::Clipboard),
    Arboard(arboard::Clipboard),
}

/// The clipboard of the display `window` is on, if it can be reached.
/// On Wayland it must be dropped before the event loop, whose connection
/// it uses.
pub fn native(window: &Window) -> Option<Box<dyn SystemClipboard>> {
    let display = window.display_handle().ok()?.as_raw();
    #[cfg(all(unix, not(target_os = "macos")))]
    if let RawDisplayHandle::Wayland(handle) = display {
        // SAFETY: the display is winit's connection, which outlives the
        // runtime that keeps this clipboard (see `gui::run`).
        let clipboard = unsafe { smithay_clipboard::Clipboard::new(handle.display.as_ptr()) };
        return Some(Box::new(Native::Wayland(clipboard)));
    }
    let _ = display;
    let clipboard = arboard::Clipboard::new().ok()?;
    Some(Box::new(Native::Arboard(clipboard)))
}

impl SystemClipboard for Native {
    fn store(&mut self, text: &str) {
        match self {
            #[cfg(all(unix, not(target_os = "macos")))]
            Self::Wayland(clipboard) => clipboard.store(text),
            Self::Arboard(clipboard) => {
                let _ = clipboard.set_text(text);
            }
        }
    }
    fn load(&mut self) -> Option<String> {
        match self {
            #[cfg(all(unix, not(target_os = "macos")))]
            Self::Wayland(clipboard) => clipboard.load().ok(),
            Self::Arboard(clipboard) => clipboard.get_text().ok(),
        }
    }
}
