//! Draws the graphical frontend's screen offscreen and writes it as an
//! image, without opening a window:
//!
//! ```sh
//! cargo run --features gui --example gui_snapshot -- \
//!     [--size 1400x900] [--scale 1.5] [--keys KEYS] [--config] --out FILE.ppm [PATH]
//! ```
//!
//! `--config` runs `init.lua`; KEYS are in `map` notation, typed after the
//! file opens.
fn main() -> std::io::Result<()> {
    let mut args = std::env::args().skip(1);
    let (mut size, mut scale, mut keys) = ((1400, 900), 1.5, String::new());
    let (mut config, mut out, mut path) = (false, None, None);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--size" => {
                let value = args.next().unwrap_or_default();
                let (w, h) = value.split_once('x').expect("--size WIDTHxHEIGHT");
                size = (w.parse().unwrap(), h.parse().unwrap());
            }
            "--scale" => scale = args.next().unwrap_or_default().parse().unwrap(),
            "--keys" => keys = args.next().unwrap_or_default(),
            "--config" => config = true,
            "--out" => out = args.next().map(std::path::PathBuf::from),
            _ => path = Some(std::path::PathBuf::from(arg)),
        }
    }
    let out = out.expect("--out FILE");
    soda::gui::snapshot(path, config, size, scale, &keys, &out)
}
