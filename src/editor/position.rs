//! Versioned document positions for results retained outside a command.
use super::{Document, DocumentId, DocumentUpdate};
use crate::core::{Association, ByteOffset, EditError};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DocumentPosition {
    pub document_id: DocumentId,
    pub revision: u64,
    pub offset: ByteOffset,
    pub association: Association,
}
impl Document {
    pub fn position(
        &self,
        offset: ByteOffset,
        association: Association,
    ) -> Result<DocumentPosition, EditError> {
        self.snapshot().text_point(offset)?;
        Ok(DocumentPosition {
            document_id: self.id(),
            revision: self.snapshot().version(),
            offset,
            association,
        })
    }
}
impl DocumentPosition {
    pub fn resolve(self, document: &Document) -> Result<ByteOffset, EditError> {
        if self.document_id != document.id() {
            return Err(EditError::WrongDocument);
        }
        if self.revision != document.snapshot().version() {
            return Err(EditError::StaleVersion);
        }
        document.snapshot().text_point(self.offset)?;
        Ok(self.offset)
    }
    /// Only an update from the same document and immediately preceding revision
    /// can map this position. Tracking drops positions inside replaced ranges.
    pub fn map(
        self,
        update: &DocumentUpdate,
        track_deletion: bool,
    ) -> Result<Option<Self>, EditError> {
        if self.document_id != update.document_id {
            return Err(EditError::WrongDocument);
        }
        if self.revision != update.before_revision {
            return Err(EditError::StaleVersion);
        }
        let offset = if track_deletion {
            update.mapping.map_tracked(self.offset.0, self.association)
        } else {
            Some(update.mapping.map(self.offset.0, self.association))
        };
        Ok(offset.map(|offset| Self {
            revision: update.after_revision,
            offset: ByteOffset(offset),
            ..self
        }))
    }
}
