//! `EncoreCore::invoke(cmd, argsJson)`: the desktop's Tauri `invoke` for the iOS app.
//!
//! Command names and argument names are exactly `ui/src/lib/api.ts`'s (`snake_case` command,
//! `camelCase` args, the way Tauri maps a Rust parameter), and every answer is the JSON the desktop
//! UI receives. So the Swift client mirrors api.ts one call per line, decodes with the same
//! `Codable` models it decodes events with, and a command the iOS app starts using later is one
//! line here over `encore_core::{api, library, audio, smart, podcasts, downloads}`, the same bodies
//! the desktop's `#[tauri::command]` wrappers call.

use std::sync::Arc;

use encore_core::state::AppState;
use encore_core::HostExt;
use innertube::{Rating, SongItem};
use serde::de::DeserializeOwned;
use serde::Serialize;
use serde_json::{Map, Value};

use encore_core::{api, audio, library};

/// The command's arguments (`{}` when none).
pub(crate) struct Args(Map<String, Value>);

impl Args {
    pub(crate) fn parse(json: &str) -> Result<Self, String> {
        if json.trim().is_empty() {
            return Ok(Args(Map::new()));
        }
        match serde_json::from_str::<Value>(json).map_err(|e| format!("bad args json: {e}"))? {
            Value::Object(m) => Ok(Args(m)),
            Value::Null => Ok(Args(Map::new())),
            other => Err(format!("args must be an object, got {other}")),
        }
    }

    /// One argument; a missing key reads as `null`, so `Option<T>` arguments may be left out.
    pub(crate) fn get<T: DeserializeOwned>(&self, key: &str) -> Result<T, String> {
        serde_json::from_value(self.0.get(key).cloned().unwrap_or(Value::Null))
            .map_err(|e| format!("argument `{key}`: {e}"))
    }
}

fn ok<T: Serialize>(v: T) -> Result<Value, String> {
    serde_json::to_value(v).map_err(|e| e.to_string())
}

/// Settings only the iOS app reads (its own Settings screens). The desktop's `set_setting` refuses
/// keys outside its `UI_SETTINGS`, so these go straight to the settings table.
pub(crate) const IOS_SETTINGS: [&str; 5] =
    ["gapless", "youtube_account", "import_onboarding_done", "episode_speed", "ios_onboarding"];

pub(crate) fn ios_setting(key: &str) -> bool {
    key.starts_with("ios_") || IOS_SETTINGS.contains(&key)
}

/// Run one command. Unknown commands are an error naming them.
pub(crate) async fn dispatch(st: &Arc<AppState>, cmd: &str, a: Args) -> Result<Value, String> {
    // stream ios-p2: the YouTube account (sign-in cookies from the app's web view).
    if let Some(r) = crate::account::dispatch(st, cmd, &a).await {
        return r;
    }
    match cmd {
        // ── search & browse ──
        "search" => ok(api::search(st, a.get("query")?, a.get::<Option<bool>>("recordHistory")?.unwrap_or(false)).await?),
        "search_all" => ok(api::search_all(st, a.get("query")?, a.get::<Option<bool>>("recordHistory")?.unwrap_or(false)).await?),
        // stream: search2
        "search_overview" => ok(encore_core::search::search_overview(st, a.get("query")?, a.get::<Option<bool>>("recordHistory")?.unwrap_or(false)).await?),
        "search_lyrics" => ok(encore_core::search::search_lyrics(st, a.get("query")?).await),
        "search_blend_lyrics" => ok(encore_core::search::blend_lyrics(&a.get::<String>("query")?, a.get("songs")?, a.get("lyric")?, a.get::<Option<bool>>("interacted")?.unwrap_or(false), a.get::<Option<String>>("topTitle")?.as_deref())),
        "search_page" => ok(encore_core::search::search_page(st, a.get("query")?, a.get("filter")?, a.get("continuation")?).await?),
        "search_suggestions" => ok(api::search_suggestions(st, a.get("query")?).await?),
        "song" => ok(api::song(st, a.get("videoId")?).await?),
        "get_home" => ok(api::get_home(st, a.get("params")?).await?),
        "get_home_more" => ok(api::get_home_more(st, a.get("token")?).await?),
        "smart_home" => ok(encore_core::smart::home::home(st).await),
        // stream magic-ib (for I-C, gap #2): only the local shelves, no network, a few ms; the instant
        // revalidate after `home-changed` `played` (D4's `home::local_home`).
        "smart_home_local" => ok(encore_core::smart::home::local_home(&st.db)),
        // stream: home-tiles-pods — Home's Podcasts chip and a podcast category's shows.
        "podcast_home" => ok(encore_core::smart::podhome::podcast_home(st).await),
        "podcast_category" => ok(encore_core::smart::podhome::podcast_category(st, a.get("genre")?).await),
        "get_moods" => ok(api::get_moods(st).await?),
        "get_mood_art" => ok(api::get_mood_art(st, a.get("params")?).await?),
        "get_browse_grid" => ok(api::get_browse_grid(st, a.get("id")?, a.get("params")?).await?),
        // Search › Browse: Charts, New releases, a genre/mood page (stream ios-sync2).
        "get_charts" => ok(encore_core::polish::explore::charts(st, a.get("country")?).await?),
        "get_new_releases" => ok(encore_core::polish::explore::new_releases(st).await?),
        "get_browse_sections" => ok(encore_core::polish::explore::browse_sections(st, a.get("browseId")?, a.get("params")?).await?),
        "get_artist_appears_on" => ok(api::get_artist_appears_on(st, a.get("id")?, a.get("songsId")?).await?),
        "get_album" => ok(api::get_album(st, a.get("id")?).await?),
        "get_artist" => ok(api::get_artist(st, a.get("id")?).await?),
        "get_playlist" => ok(api::get_playlist(st, a.get("id")?, a.get("sort")?, a.get("desc")?).await?),
        // stream magic-ib: write a playlist's order back to YouTube (own synced playlists; gap #25).
        "set_playlist_sort" => ok(api::set_playlist_sort(st, a.get("playlistId")?, a.get("sort")?).await?),
        "get_playlist_more" =>ok(api::get_playlist_more(st, a.get("token")?, a.get("total")?).await?),
        "get_lyrics" => ok(api::get_lyrics(
            st,
            a.get("videoId")?,
            a.get("title")?,
            a.get("artists")?,
            a.get("album")?,
            a.get("duration")?,
            a.get("searched")?,
            a.get("source")?,
        )
        .await?),
        // The lyrics ⋯ menu: Lyrics source and Timing.
        "choose_lyrics_source" => ok(api::choose_lyrics_source(
            st,
            a.get("videoId")?,
            a.get("title")?,
            a.get("artists")?,
            a.get("album")?,
            a.get("duration")?,
            a.get("searched")?,
            a.get("source")?,
        )
        .await?),
        "set_lyrics_offset" => ok(api::set_lyrics_offset(st, a.get("videoId")?, a.get("offsetMs")?)),
        "lyrics_providers" => ok(api::lyrics_providers(st)),

        // ── play queue ──
        "play" => ok(api::play_single(st, a.get("item")?, a.get("from")?).await?),
        "hint_play" => ok(api::hint_play(st, a.get("item")?)),
        "play_index" => ok(api::play_index(st, a.get("index")?, a.get("start")?).await?),
        "play_playlist" => ok(api::play_playlist(
            st,
            a.get("items")?,
            a.get("start")?,
            a.get("sourceId")?,
            a.get("sourceName")?,
            a.get("shuffle")?,
            a.get("continuation")?,
            a.get("context")?,
            a.get("startSecs")?,
        )
        .await?),
        // stream magic-ib (lane D1's commands): a radio as a page without playing (gap #1), a song
        // link's single pick at `start` s, song credits (#6), and taste exclusion (#16).
        "radio_tracks" => ok(encore_core::radio_page::radio_tracks(st, &a.get::<String>("kind")?, &a.get::<String>("id")?, a.get("name")?).await?),
        "play_single_at" => ok(encore_core::radio_page::play_single_at(st, a.get("item")?, a.get("from")?, a.get("start")?).await?),
        "song_credits" => ok(encore_core::credits::song_credits(st, a.get("item")?).await?),
        "discography" => discography(&a),
        "taste_set_excluded" => {
            let (id, kind, title): (String, String, Option<String>) = (a.get("id")?, a.get("kind")?, a.get("title")?);
            let ids: Vec<String> = a.get("videoIds")?;
            encore_core::smart::taste::set_excluded(&st.db, &id, &kind, title.as_deref(), &ids, a.get("excluded")?);
            ok(())
        }
        "taste_excluded" => ok(encore_core::smart::taste::excluded_ids(&st.db)),
        // stream magic-ib (I-B2, SYNC-GAPS §1): the desktop commands iOS had no bridge for.
        "restore_queued" => ok(st.clone().restore_queued(a.get("items")?).await),
        "smart_tags_liked" => ok(encore_core::smart::tags::liked_chips(st)),
        "enhance_state" => ok(encore_core::smart::smartshuffle::enhance_state(st, &a.get::<String>("playlistId")?).await),
        "enhance_set" => ok(encore_core::smart::smartshuffle::enhance_set(st, &a.get::<String>("playlistId")?, a.get("on")?, a.get("len")?).await?),
        "enhance_remove" => ok(encore_core::smart::smartshuffle::enhance_remove(st, &a.get::<String>("playlistId")?, &a.get::<String>("videoId")?).await),
        "enhance_keep" => ok(encore_core::smart::smartshuffle::enhance_keep(st, &a.get::<String>("playlistId")?, &a.get::<String>("videoId")?)),
        "lib_deleted_playlists" => ok(library::lib_deleted_playlists(st).await?),
        "lib_recent_tracks" => ok(library::lib_recent_tracks(st, a.get("limit")?).await?),
        "listening_stats" => ok(api::listening_stats(st, a.get("since")?)),
        "top_artists" => ok(api::top_artists(st, a.get("limit")?)),
        "clear_listening_history" => {
            api::clear_listening_history(st);
            ok(())
        }
        "get_blocked_artists" => ok(api::get_blocked_artists(st).await?),
        "block_artist" => ok(api::block_artist(st, a.get("id")?, a.get("name")?).await?),
        "unblock_artist" => ok(api::unblock_artist(st, a.get("key")?).await?),
        "lib_folder_rename" => ok(library::lib_folder_rename(st, a.get("id")?, a.get("name")?).await?),
        "lib_folder_delete" => ok(library::lib_folder_delete(st, a.get("id")?).await?),
        "lib_folder_restore" => ok(library::lib_folder_restore(st, a.get("snapshot")?).await?),
        "set_playlist_cover" => ok(api::set_playlist_cover(st, a.get("playlistId")?, a.get("path")?).await?),
        "start_radio" => ok(api::start_radio(st, a.get("kind")?, a.get("id")?, a.get("name")?, a.get("start")?).await?),
        "next_track" => ok(api::next_track(st).await?),
        "prev_track" => ok(api::prev_track(st).await?),
        "toggle_pause" => ok(api::toggle_pause(st).await?),
        "seek" => ok(api::seek(st, a.get("position")?).await?),
        "toggle_shuffle" => ok(api::toggle_shuffle(st).await?),
        "set_repeat" => ok(api::set_repeat(st, a.get("mode")?).await?),
        "add_to_queue" => ok(api::add_to_queue(st, a.get("items")?, a.get("from")?, a.get("continuation")?).await?),
        "play_next" => ok(api::play_next(st, a.get("items")?, a.get("from")?).await?),
        "remove_from_queue" => ok(api::remove_from_queue(st, a.get("index")?).await?),
        "move_in_queue" => ok(api::move_in_queue(st, a.get("from")?, a.get("to")?).await?),
        "clear_queued" => ok(api::clear_queued(st).await?),
        "get_queue" => ok(api::get_queue(st).await?),
        "get_playback" => ok(api::get_playback(st).await?),
        "playback_clock" => ok(api::playback_clock(st).await?),
        "set_playback_params" => {
            let (_, semitones, reverb) = st.player.playback_params();
            let semitones = a.get::<Option<i32>>("semitones")?.unwrap_or(semitones);
            let reverb = a.get::<Option<player::Reverb>>("reverb")?.unwrap_or(reverb);
            let target = a.get::<Option<String>>("target")?;
            ok(api::set_playback_params(st, a.get("speed")?, semitones, reverb, target).await?)
        }
        "set_volume" => {
            let v: i64 = a.get("volume")?;
            st.player.set_volume(v).map_err(|e| e.to_string())?;
            ok(())
        }
        "rate" => ok(api::rate(st, a.get("videoId")?, a.get::<Rating>("rating")?).await?),

        // ── device sync (docs/SYNC.md); `sync-changed` events ──
        "sync_status" => ok(encore_core::sync::sync_status().await?),
        "sync_start_pairing" => ok(encore_core::sync::sync_start_pairing().await?),
        "sync_cancel_pairing" => ok(encore_core::sync::sync_cancel_pairing().await?),
        "sync_join" => ok(encore_core::sync::sync_join(a.get("code")?, a.get("qr")?, a.get("host")?, a.get("port")?).await?),
        "sync_unpair" => ok(encore_core::sync::sync_unpair().await?),
        "sync_now" => ok(encore_core::sync::sync_now().await?),
        "sync_set_active" => ok(encore_core::sync::sync_set_active(a.get("active")?).await?),
        // "Playing on <device>" (presence.rs); `presence-changed` events
        "presence_list" => ok(encore_core::sync::presence_list(st).await?),
        "presence_send" => ok(encore_core::sync::presence_send(st, a.get("dev")?, a.get("cmd")?).await?),

        // ── library (local, no account) ──
        "lib_snapshot" => ok(library::lib_snapshot(st).await?),
        "lib_liked_songs" => ok(library::lib_liked_songs(st).await?),
        "lib_like" => ok(library::lib_like(st, a.get::<Vec<SongItem>>("songs")?).await?),
        "lib_unlike" => ok(library::lib_unlike(st, a.get("videoIds")?).await?),
        "lib_save" => ok(library::lib_save(st, a.get("card")?, a.get("synced")?).await?),
        "lib_unsave" => ok(library::lib_unsave(st, a.get("id")?).await?),
        "lib_playlists" => ok(library::lib_playlists(st).await?),
        "lib_playlist_create" => ok(library::lib_playlist_create(st, a.get("name")?, a.get("description")?, a.get("folderId")?).await?),
        "lib_playlist_remove_videos" => ok(library::lib_playlist_remove_videos(st, a.get("id")?, a.get("videoIds")?).await?),
        "lib_playlists_containing" => ok(library::lib_playlists_containing(st, a.get("videoId")?).await?),
        "lib_playlist_add" => ok(library::lib_playlist_add(st, a.get("id")?, a.get("songs")?, a.get("allowDuplicates")?, a.get("position")?).await?),
        "lib_hide_song" => ok(library::lib_hide_song(st, a.get("videoId")?, a.get("song")?, a.get("contextId")?).await?),
        "lib_unhide_song" => ok(library::lib_unhide_song(st, a.get("videoId")?, a.get("contextId")?).await?),
        "lib_hidden_songs" => ok(library::lib_hidden_songs(st, a.get("contextId")?).await?),
        "lib_playlist_update" => ok(library::lib_playlist_update(st, a.get("id")?, a.get("name")?, a.get("description")?).await?),
        "lib_playlist_delete" => ok(library::lib_playlist_delete(st, a.get("id")?).await?),
        "lib_playlist_restore" => ok(library::lib_playlist_restore(st, a.get("id")?).await?),
        "lib_playlist_entries" => ok(library::lib_playlist_entries(st, a.get("id")?).await?),
        "lib_playlist_remove" => ok(library::lib_playlist_remove(st, a.get("id")?, a.get("rowIds")?).await?),
        "lib_playlist_insert_entries" => ok(library::lib_playlist_insert_entries(st, a.get("id")?, a.get("entries")?).await?),
        "lib_playlist_set_order" => ok(library::lib_playlist_set_order(st, a.get("id")?, a.get("rowIds")?).await?),
        "lib_folder_create" => ok(library::lib_folder_create(st, a.get("name")?, a.get("parentId")?).await?),
        "lib_folder_set_item" => ok(library::lib_folder_set_item(st, a.get("itemId")?, a.get("folderId")?, a.get("index")?).await?),
        "lib_pins" => ok(library::lib_pins(st).await?),
        "lib_pin" => ok(library::lib_pin(st, a.get("itemId")?, a.get("kind")?, a.get("index")?).await?),
        "lib_unpin" => ok(library::lib_unpin(st, a.get("itemId")?).await?),
        "lib_note_played" => ok(library::lib_note_played(st, a.get("itemId")?, a.get("kind")?, a.get("card")?).await?),
        "lib_recent_contexts" => ok(library::lib_recent_contexts(st, a.get("limit")?).await?),
        "lib_set_private_session" => ok(library::lib_set_private_session(st, a.get("enabled")?).await?),
        "lib_mark_synced" => ok(library::lib_mark_synced(st, a.get("ids")?, a.get("synced")?).await?),

        // ── the signed-in YouTube account's library and playlist edits (stream ios-sync2) ──
        "get_library" => ok(api::get_library(st).await?),
        "get_library_albums" => ok(api::get_library_albums(st).await?),
        "get_library_artists" => ok(api::get_library_artists(st).await?),
        "get_library_subscriptions" => ok(api::get_library_subscriptions(st).await?),
        "subscribe" => ok(api::subscribe(st, a.get("channelId")?, a.get("subscribed")?).await?),
        "set_album_saved" => ok(api::set_album_saved(st, a.get("playlistId")?, a.get("saved")?).await?),
        "playlist_index" => ok(api::playlist_index(st)),
        "sync_playlist_index" => ok(api::sync_playlist_index(st).await?),
        "readonly_playlists" => ok(api::readonly_playlists(st)),
        "create_playlist" => ok(api::create_playlist(st, a.get("title")?, a.get("local")?).await?),
        "edit_playlist_details" => ok(api::edit_playlist_details(st, a.get("playlistId")?, a.get("name")?, a.get("description")?, a.get("public")?).await?),
        "delete_playlist" => ok(api::delete_playlist(st, a.get("playlistId")?).await?),
        "add_to_playlist" => ok(api::add_to_playlist(st, a.get("playlistId")?, a.get("videoId")?, a.get("allowDuplicates")?).await?),
        "remove_from_playlist" => ok(api::remove_from_playlist(st, a.get("playlistId")?, a.get("videoId")?, a.get("setVideoId")?).await?),
        "remove_many_from_playlist" => ok(api::remove_many_from_playlist(st, a.get("playlistId")?, a.get("tracks")?).await?),
        "move_in_playlist" => ok(api::move_in_playlist(st, a.get("playlistId")?, a.get("setVideoId")?, a.get("beforeSetVideoId")?).await?),

        // ── stream: audiobooks ── LibriVox books (crates/core/src/audiobooks).
        "audiobook_search" => ok(encore_core::audiobooks::api::audiobook_search(st, a.get("query")?).await?),
        "audiobook_home" => ok(encore_core::audiobooks::api::audiobook_home(st).await),
        "audiobook_genre" => ok(encore_core::audiobooks::api::audiobook_genre(st, a.get("genre")?, a.get("page")?).await?),
        "audiobook_page" => ok(encore_core::audiobooks::api::audiobook_page(st, a.get("id")?).await?),
        "audiobook_for_chapter" => ok(encore_core::audiobooks::api::audiobook_for_chapter(st, a.get("id")?).await?),
        "audiobook_save" => ok(encore_core::audiobooks::api::audiobook_save(st, a.get("book")?, a.get("saved")?)?),
        "audiobook_saved" => ok(encore_core::audiobooks::api::audiobook_saved(st)?),

        // ── podcasts ──
        "podcast_search" => ok(encore_core::podcasts::api::podcast_search(st, a.get("query")?, a.get("scope")?).await?),
        "podcast_show" => ok(encore_core::podcasts::api::podcast_show(st, a.get("id")?, a.get("sort")?).await?),
        "podcast_show_more" => ok(encore_core::podcasts::api::podcast_show_more(st, a.get("id")?, a.get("continuation")?, a.get("sort")?).await?),
        "podcast_episode" => ok(encore_core::podcasts::api::podcast_episode(st, a.get("id")?).await?),
        "podcast_chapters" => ok(encore_core::podcasts::api::podcast_chapters(st, a.get("id")?, a.get("durationSecs")?).await?),
        // stream: video-pods
        "podcast_episode_video" => ok(encore_core::podcasts::video::podcast_episode_video(&st.db, &a.get::<String>("id")?)),
        "podcast_follow" => ok(encore_core::podcasts::api::podcast_follow(st, a.get("show")?).await?),
        "podcast_unfollow" => {
            let id: String = a.get("id")?;
            ok(podcast_store::unfollow(&st.db.podcasts_conn(), &id).map_err(|e| e.to_string())?)
        }
        "podcast_follows" => ok(podcast_store::follows(&st.db.podcasts_conn()).map_err(|e| e.to_string())?),
        "podcast_new_episodes" => {
            let since = encore_core::podcasts::now_secs() - a.get::<Option<i64>>("days")?.unwrap_or(30) * 86_400;
            let limit = a.get::<Option<usize>>("limit")?.unwrap_or(100);
            ok(podcast_store::new_episodes(&st.db.podcasts_conn(), since, limit).map_err(|e| e.to_string())?)
        }
        "podcast_continue_listening" => {
            let limit = a.get::<Option<usize>>("limit")?.unwrap_or(20);
            ok(podcast_store::continue_listening(&st.db.podcasts_conn(), limit).map_err(|e| e.to_string())?)
        }
        "podcast_saved_episodes" => ok(podcast_store::saved_episodes(&st.db.podcasts_conn()).map_err(|e| e.to_string())?),
        "podcast_save_episode" => {
            let ep: encore_core::podcasts::Episode = a.get("episode")?;
            let saved: bool = a.get("saved")?;
            ok(podcast_store::set_saved(&st.db.podcasts_conn(), &ep, saved).map_err(|e| e.to_string())?)
        }
        "podcast_mark_played" => {
            let (id, played): (String, bool) = (a.get("id")?, a.get("played")?);
            let conn = st.db.podcasts_conn();
            podcast_store::set_played(&conn, &id, played).map_err(|e| e.to_string())?;
            ok(podcast_store::progress(&conn, &id).unwrap_or_default())
        }
        // Settings › Podcasts: SponsorBlock, ad-free YouTube twins, OPML.
        "podcast_settings" => ok(encore_core::podcasts::api::podcast_settings(&st.db)),
        "podcast_set_settings" => ok(encore_core::podcasts::api::podcast_set_settings(&st.db, &a.get::<Value>("settings")?)),
        "podcast_youtube_match" => ok(encore_core::polish::podmatch::enabled(&st.db)),
        "podcast_set_youtube_match" => ok(encore_core::polish::podmatch::set_enabled(&st.db, a.get("on")?)),
        "podcast_opml_export" => ok(encore_core::podcasts::api::podcast_opml_export(&st.db.podcasts_conn())?),
        "podcast_opml_import" => ok(encore_core::podcasts::api::podcast_opml_import(st, &a.get::<String>("xml")?)?),

        // ── audio ──
        "audio_settings" => ok(audio::audio_settings(st).await?),
        "audio_eq_info" => ok(audio::audio_eq_info()),
        "set_eq" => ok(audio::set_eq(st, a.get("enabled")?, a.get("gains")?, a.get("commit")?).await?),
        "set_eq_preset" => ok(audio::set_eq_preset(st, a.get("name")?).await?),
        "set_normalize_volume" => ok(audio::set_normalize_volume(st, a.get("on")?).await?),
        "set_volume_level" => ok(audio::set_volume_level(st, a.get("level")?).await?),
        "set_crossfade_secs" => ok(audio::set_crossfade_secs(st, a.get("secs")?).await?),
        "set_sleep_timer" => ok(audio::set_sleep_timer(st, a.get("minutes")?, a.get("endOfTrack")?).await?),
        "cancel_sleep_timer" => ok(audio::cancel_sleep_timer(st).await?),
        "sleep_timer" => ok(audio::sleep_timer().await?),

        // ── smart (smart.md, smart2.md) ──
        "smart_settings" => {
            use encore_core::smart::settings as s;
            ok(serde_json::json!({
                "shuffle_mode": if s::smart_shuffle(&st.db) { "smart" } else { "standard" },
                "explicit_filter": s::explicit_filter(&st.db),
                "private_session": s::private_session(&st.db),
            }))
        }
        "smart_set_setting" => {
            use encore_core::smart::settings as s;
            let (key, value): (String, String) = (a.get("key")?, a.get("value")?);
            if ![s::SHUFFLE_MODE, s::EXPLICIT_FILTER].contains(&key.as_str()) {
                return Err(format!("unknown smart setting: {key}"));
            }
            st.db.set_setting(&key, &value);
            ok(())
        }
        // A Home "Your Mix" tile (`dailymix:<artist keys>`): its songs, as the desktop's mix page loads them.
        "smart_mix" => ok(encore_core::smart::home::mix_tracks(
            st,
            &a.get::<String>("id")?,
            a.get::<Option<usize>>("size")?.unwrap_or(50).clamp(10, 100),
        )
        .await?),
        "made_for_you" => {
            if a.get::<Option<bool>>("refresh")?.unwrap_or(false) {
                encore_core::smart::mfy::refresh(st, true).await;
            }
            ok(encore_core::smart::mfy::cards(st).await)
        }
        "whats_new" => {
            if a.get::<Option<bool>>("refresh")?.unwrap_or(false) {
                encore_core::smart::whatsnew::refresh(st, true).await;
            }
            ok(encore_core::smart::whatsnew::whats_new(&st.db))
        }
        "whats_new_count" => ok(encore_core::smart::whatsnew::new_count(&st.db)),
        "whats_new_mark_seen" => {
            encore_core::smart::whatsnew::mark_seen(&st.db);
            let _ = st.host.emit("whats-new-changed", serde_json::json!({ "newCount": 0 }));
            ok(())
        }
        // stream magic-ib: the "Recommended" footer under your own playlists (gap #4); the same
        // bounds as the desktop's `smart::commands::playlist_recommendations`.
        "playlist_recommendations" => ok(encore_core::smart::recs::playlist_recommendations(
            st,
            &a.get::<String>("playlistId")?,
            a.get::<Option<usize>>("n")?.unwrap_or(10).clamp(1, 50),
            a.get::<Option<usize>>("refresh")?.unwrap_or(0),
        )
        .await?),
        // Rows that may play / are explicit (search and entity rows grey them; gaps #29, #23).
        "playable_flags" => {
            let items: Vec<SongItem> = a.get("items")?;
            let f = encore_core::smart::library::Filter::load(&st.db);
            ok(items.iter().map(|s| (s.video_id.clone(), !f.rejects(s))).collect::<std::collections::HashMap<_, _>>())
        }
        "explicit_flags" => {
            let items: Vec<SongItem> = a.get("items")?;
            let mut f = encore_core::smart::library::Filter::load(&st.db);
            if a.get::<Option<bool>>("lookup")?.unwrap_or(false) {
                encore_core::smart::explicit::resolve_unknown(&st.db, &items, &mut f, 25).await;
            }
            ok(items.iter().map(|s| (s.video_id.clone(), f.is_explicit(s))).collect::<std::collections::HashMap<_, _>>())
        }
        "smart_shuffle_state" => ok(encore_core::smart::smartshuffle::sync(st).await),
        "smart_shuffle_set" => ok(encore_core::smart::smartshuffle::set(st, a.get("on")?).await?),
        "smart_shuffle_remove" => ok(encore_core::smart::smartshuffle::remove(st, &a.get::<String>("videoId")?).await),
        "smart_shuffle_keep" => ok(encore_core::smart::smartshuffle::keep(st, &a.get::<String>("videoId")?)),

        // ── downloads ──
        "downloads_snapshot" => ok(dl()?.snapshot()),
        "song_export" => ok(encore_core::downloads::fetch::export_aac(st, &a.get::<String>("videoId")?, std::path::Path::new(&a.get::<String>("path")?)).await?),
        "downloads_add" => ok(dl()?.add(a.get("collection")?, a.get("songs")?).await?),
        "downloads_remove" => {
            dl()?.remove(&a.get::<String>("id")?);
            ok(())
        }
        "downloads_remove_all" => {
            dl()?.remove_all();
            ok(())
        }
        "downloads_retry" => {
            dl()?.retry();
            ok(())
        }
        "downloads_collection_songs" => ok(encore_core::downloads::store::collection_songs(&st.db.conn(), &a.get::<String>("id")?)),
        "downloads_songs" => ok(encore_core::downloads::store::done_songs(&st.db.conn())),
        "downloads_set_settings" => {
            #[derive(serde::Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Patch {
                offline_mode: Option<bool>,
                allow_metered: Option<bool>,
                quality: Option<String>,
            }
            let p: Patch = a.get("patch")?;
            let m = dl()?;
            if let Some(on) = p.offline_mode {
                m.set_offline_mode(on);
            }
            if let Some(on) = p.allow_metered {
                m.set_allow_metered(on);
            }
            if let Some(q) = p.quality {
                let q = if q.eq_ignore_ascii_case("low") { "LOW" } else { "HIGH" };
                st.db.set_setting(encore_core::downloads::SET_QUALITY, q);
            }
            ok(m.snapshot())
        }

        // ── settings ──
        "get_settings" => {
            let mut v = api::get_settings(st).await?;
            if let Value::Object(m) = &mut v {
                for (k, val) in ios_settings(st) {
                    m.insert(k, Value::String(val));
                }
            }
            Ok(v)
        }
        "set_setting" => {
            let (key, value): (String, String) = (a.get("key")?, a.get("value")?);
            if ios_setting(&key) {
                st.db.set_setting(&key, &value);
                return ok(());
            }
            ok(api::set_setting(st, &key, &value).await?)
        }

        "cache_size" => ok(api::cache_size(st).await?),
        "clear_caches" => ok(api::clear_caches(st).await?),

        // ── Spotify import ──
        "import_read" => ok(api::import_read(a.get("link")?, a.get("path")?).await?),
        "import_start" => ok(api::import_start(st, a.get("lists")?).await?),
        "import_create" => ok(api::import_create(st, a.get("options")?).await?),
        "import_status" => ok(api::import_status().await?),
        // Recently played's grid of the albums/playlists you played from (both apps).
        "recent_play_contexts" => ok(encore_core::polish::context::recent_play_contexts(&st.db, a.get("limit")?)),
        // First-run import offer: one rule for both apps (`library::import_offer`).
        "import_offer" => ok(encore_core::library::import_offer_db(&st.db)),
        "import_offer_done" => ok(encore_core::library::import_offer_done(&st.db)),
        // stream: ios-import-review: the review step (To check / Not found / Matched).
        "import_rows" => ok(api::import_rows(a.get("tier")?).await?),
        "import_pick" => ok(api::import_pick(st, a.get("key")?, a.get("song")?).await?),
        "import_cancel" => ok(api::import_cancel(st).await?),
        // A Spotify track / album / artist link: the song to play or the page to open.
        "import_resolve" => ok(api::import_resolve(st, a.get("link")?).await?),
        // Settings › Account › Export library: the zip lands at `path` (iOS: a temp file it shares).
        "lib_export" => ok(library::lib_export(st, a.get("path")?).await?),

        _ => Err(format!("unknown command: {cmd}")),
    }
}

use encore_core::podcasts::store as podcast_store;

/// `discography`: pure, so the mock client calls it too (`crate::discography`).
pub(crate) fn discography(a: &Args) -> Result<Value, String> {
    let albums: Vec<Value> = a.get::<Option<_>>("albums")?.unwrap_or_default();
    let singles: Vec<Value> = a.get::<Option<_>>("singles")?.unwrap_or_default();
    let songs: Vec<SongItem> = a.get::<Option<_>>("topSongs")?.unwrap_or_default();
    ok(encore_core::discography::build_now(&albums, &singles, &songs))
}

fn dl() -> Result<&'static Arc<encore_core::downloads::Manager>, String> {
    encore_core::downloads::mgr().ok_or_else(|| "downloads are not ready".to_owned())
}

/// The iOS-only settings that are set, for `get_settings`.
fn ios_settings(st: &AppState) -> Vec<(String, String)> {
    let conn = st.db.conn();
    let mut out = Vec::new();
    if let Ok(mut q) = conn.prepare("SELECT key, value FROM settings WHERE key LIKE 'ios\\_%' ESCAPE '\\'") {
        if let Ok(rows) = q.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))) {
            out.extend(rows.flatten());
        }
    }
    drop(conn);
    for k in IOS_SETTINGS {
        if let Some(v) = st.db.get_setting(k) {
            out.push((k.to_owned(), v));
        }
    }
    out
}
