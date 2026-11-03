//! Shared session transition protocol. The layer manager applies lifecycle
//! changes; Runtime executes returned events and effects after reduction.
use super::{Input, InputUpdate, Presentation, Response, TextInput};

pub(super) enum Transition {
    Blocked,
    Active(Response),
    Closed(Response),
}
impl Transition {
    pub fn redraw() -> Self {
        Self::Active(Response {
            redraw: true,
            ..Response::default()
        })
    }
    pub fn close() -> Self {
        Self::Closed(Response {
            redraw: true,
            ..Response::default()
        })
    }
}
pub(super) fn edit_field(field: &mut TextInput, input: Input) -> Option<InputUpdate> {
    match input {
        Input::Text(key) => Some(field.key(key)),
        Input::Paste(text) => Some(field.insert(&text)),
        _ => None,
    }
}
pub(super) fn field_presentation(label: String, field: &TextInput) -> Presentation {
    let selection = field.selection().range();
    Presentation {
        cursor: Some(label.len() + field.cursor()),
        selection: label.len() + selection.start..label.len() + selection.end,
        text: format!("{label}{}", field.text()),
    }
}
