//! Command palette: every registered command name, filtered by the query.
//! Commands needing an argument continue in a prefilled command line.
use super::{
    Command, Input, Presentation, Response, TextInput,
    list::{ListInput, ListSession},
    picker::{CandidateKey, CandidateListState, MatchedCandidate},
    registry::{CommandInfo, Registry},
    session::Transition,
};

pub struct PaletteSession {
    commands: Vec<CommandInfo>,
    list: ListSession<usize>,
}
impl PaletteSession {
    pub fn new(registry: &Registry) -> Self {
        let mut session = Self {
            commands: registry.commands(),
            list: ListSession::new("Command: ", ""),
        };
        session.list.restart(session.matching());
        session
    }
    pub fn input(&self) -> &TextInput {
        self.list.input()
    }
    pub fn rows(&self) -> &[MatchedCandidate<usize>] {
        self.list.rows()
    }
    pub fn list(&self) -> &CandidateListState {
        self.list.list()
    }
    pub(super) fn resize(&mut self, rows: usize) {
        self.list.resize(rows);
    }
    fn matching(&self) -> Vec<(CandidateKey, String, usize)> {
        let query = self.list.query().to_lowercase();
        self.commands
            .iter()
            .enumerate()
            .filter(|(_, info)| {
                info.name.contains(&query) || info.doc.to_lowercase().contains(&query)
            })
            .map(|(index, info)| {
                let name = if info.args.is_empty() {
                    info.name.clone()
                } else {
                    format!("{} {}", info.name, info.args)
                };
                (
                    CandidateKey(index as u64),
                    format!("{name:<28} {}", info.doc),
                    index,
                )
            })
            .collect()
    }
    pub(super) fn handle(&mut self, input: Input) -> Transition {
        match self.list.handle(input) {
            ListInput::Cancel => Transition::close(),
            ListInput::Accept(None) => Transition::redraw(),
            ListInput::Accept(Some(&index)) => {
                let info = &self.commands[index];
                let command = if info.args.is_empty() || info.args.starts_with('[') {
                    Command::Named(info.name.clone())
                } else {
                    Command::Ex(format!("{} ", info.name))
                };
                Transition::finished(Response {
                    commands: vec![command],
                    redraw: true,
                    ..Response::default()
                })
            }
            ListInput::Query => {
                let rows = self.matching();
                self.list.restart(rows);
                Transition::redraw()
            }
            ListInput::Redraw => Transition::redraw(),
            ListInput::Blocked => Transition::Blocked,
        }
    }
    pub(super) fn presentation(&self) -> Presentation {
        self.list.presentation()
    }
}
