// SPDX-License-Identifier: GPL-3.0-or-later
// Pocket Sync / pupdate plugin (openfpga-library/pocket-plugin) for the
// NDS_Pocket DS core: ROM tables, game files and compressed ROMs on the SD
// card (docs/pocket-plugin.md). Modelled on openfpga-PlayStation's plugin.


pub mod card;
pub mod compress;
pub mod formats;
pub mod games;
pub mod lz4;
pub mod rom;
mod romlist;

pub const CARD: &str = "pocket";

/// A plugin config value (hosts set none; tests and the compression
/// setting use them).
#[cfg(target_arch = "wasm32")]
pub fn config(key: &str) -> Option<String> { extism_pdk::config::get(key).ok().flatten() }
#[cfg(not(target_arch = "wasm32"))]
pub fn config(key: &str) -> Option<String> { std::env::var(format!("DS_PLUGIN_{}", key.to_ascii_uppercase())).ok() }

#[cfg(target_arch = "wasm32")]
mod plugin {
    use super::*;
    use crate::card::mb;
    use std::path::Path;
    use crate::compress::{self, Mode};
    use crate::games::{self, Core};
    use extism_pdk::*;
    use serde::{Deserialize, Serialize};

    const MAKE: &str = "Generate Game Files";
    const COMPRESS: &str = "Compress ROMs";
    const KEEP: &str = "Compress, Keep the Originals";
    const REPLACE: &str = "Compress, Replace the Originals";
    const EXIT: &str = "Exit";

    #[derive(Clone, Serialize, ToBytes)]
    #[encoding(Json)]
    pub enum PluginMessage {
        Choice { name: String, query: String, choices: Vec<String> },
        #[allow(dead_code)] // part of the host protocol; this plugin never asks for text
        Text { name: String, query: String },
        Exit,
    }

    #[derive(Clone, Deserialize, FromBytes)]
    #[encoding(Json)]
    pub enum HostMessage {
        Answer { name: String, value: String },
        Kill,
    }

    #[host_fn]
    extern "ExtismHost" {
        fn open_url(url: &str) -> ();
        fn print_msg(message: &str) -> ();
    }

    fn println(msg: &str) {
        unsafe {
            let _ = print_msg(&format!("{msg}\n"));
        }
    }

    fn core(id: &str) -> Option<Core> { games::find_cores(Path::new(CARD)).into_iter().find(|c| c.id == id) }

    /// Compression stays behind a setting until the core reads .ndz files:
    /// the core's ROM slot taking them, or the plugin config compress=1.
    fn compression_on(core: &Core) -> bool { core.reads_ndz || config("compress").as_deref() == Some("1") }

    fn menu(id: &str) -> PluginMessage {
        let Some(core) = core(id) else { return PluginMessage::Exit };
        let mut choices = vec![MAKE.to_string()];
        if compression_on(&core) {
            let jobs = compress::plan(Path::new(CARD), &core.platform);
            if !jobs.is_empty() {
                let bytes: u64 = jobs.iter().map(|j| j.bytes).sum();
                choices.push(format!("{COMPRESS} ({} ROMs, {} MB)", jobs.len(), mb(bytes)));
            }
        }
        choices.push(EXIT.into());
        PluginMessage::Choice { name: format!("action:{id}"), query: format!("DS game files for {id}"), choices }
    }

    fn compress_menu(id: &str) -> PluginMessage {
        let Some(core) = core(id) else { return PluginMessage::Exit };
        let jobs = compress::plan(Path::new(CARD), &core.platform);
        for job in &jobs {
            println(&format!("can be compressed: {} ({} MB)", card::name_of(&job.nds), mb(job.bytes)));
        }
        let note = if core.reads_ndz { "" } else { " This core can't read compressed ROMs yet, so keep the originals." };
        PluginMessage::Choice {
            name: format!("compress:{id}"),
            query: format!("Compress {} ROMs? Each .ndz is checked against its ROM before an original is removed.{note}", jobs.len()),
            choices: vec![KEEP.into(), REPLACE.into(), MAKE.into(), EXIT.into()],
        }
    }

    fn run(id: &str, mode: Option<Mode>) -> PluginMessage {
        let card = Path::new(CARD);
        let Some(core) = core(id) else {
            println(&format!("{id} is no longer on the SD card."));
            return PluginMessage::Exit;
        };
        compress::resume(card, &mut |line| println(line));
        let left = card::clean_leftovers(card, &core.platform);
        if left > 0 {
            println(&format!("Removed {left} unfinished file(s) from an earlier run that was stopped part-way."));
        }
        if let Some(mode) = mode {
            let jobs = compress::plan(card, &core.platform);
            compress::run(card, &core.platform, &jobs, mode, &mut |line| println(line));
        }
        println(&format!("Looking for games in Assets/{}/common ...", core.platform));
        match games::make_game_files(card, &core, &mut |line| println(line)) {
            Ok(s) => {
                println(&format!(
                    "{} ROM tables ({} new or changed), {} game files in Assets/{}/{}, {} skipped",
                    s.tables, s.tables_written, s.instances, core.platform, core.id, s.failed
                ));
                if !core.takes_game_files() {
                    println(&format!("{id} doesn't take game files (.json) yet, so only the ROM tables (.ndt) were written."));
                } else if s.instances > 0 {
                    println("Done. Start a game from its .json in the core's file list.");
                }
            }
            Err(error) => println(&format!("Stopped: {error}")),
        }
        PluginMessage::Exit
    }

    #[plugin_fn]
    pub fn start() -> FnResult<PluginMessage> {
        println("DS Game Files");
        let cores = games::find_cores(Path::new(CARD));
        Ok(match cores.len() {
            0 => {
                println("No DS core found in Cores/ on this SD card. Install the core first.");
                PluginMessage::Exit
            }
            1 => menu(&cores[0].id),
            _ => {
                let mut choices: Vec<String> = cores.into_iter().map(|c| c.id).collect();
                choices.push(EXIT.into());
                PluginMessage::Choice { name: "core".into(), query: "Which DS core are the game files for?".into(), choices }
            }
        })
    }

    #[plugin_fn]
    pub fn handle_response(input: HostMessage) -> FnResult<PluginMessage> {
        Ok(match input {
            HostMessage::Answer { value, .. } if value == EXIT => PluginMessage::Exit,
            HostMessage::Answer { name, value } if name == "core" => menu(&value),
            HostMessage::Answer { name, value } => {
                if let Some(id) = name.strip_prefix("action:") {
                    if value == MAKE { run(id, None) } else if value.starts_with(COMPRESS) { compress_menu(id) } else { PluginMessage::Exit }
                } else if let Some(id) = name.strip_prefix("compress:") {
                    match value.as_str() {
                        KEEP => run(id, Some(Mode::Keep)),
                        REPLACE => run(id, Some(Mode::Replace)),
                        MAKE => run(id, None),
                        _ => PluginMessage::Exit,
                    }
                } else {
                    PluginMessage::Exit
                }
            }
            HostMessage::Kill => PluginMessage::Exit,
        })
    }
}
