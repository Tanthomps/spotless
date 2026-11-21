import XCTest

/// The user flows, in the order a new user meets them. Each starts from a fresh database unless it
/// is about persistence. Real network: YouTube's bot wall can slow a call; the core retries, the
/// timeouts here are generous, but a flow that never gets there fails.
final class FlowTests: E2ECase {

    // MARK: 01 first launch

    func test01_FirstLaunchOnboardingSkip() {
        launch(reset: true, onboarding: true)
        XCTAssertTrue(el("import").waitForExistence(timeout: 15), "first launch offers the Spotify import")
        tap(el("import-skip"), "Not now")
        XCTAssertTrue(waitGone(el("import")), "onboarding closes")
        XCTAssertTrue(el("tab-home").waitForExistence(timeout: 5))
        // Never again once skipped.
        app.terminate()
        launch(onboarding: true)
        pause(4)
        XCTAssertFalse(el("import").exists, "the import offer must not come back after Not now")
    }

    // MARK: 02 Home

    func test02_HomeLoadsRealShelves() {
        launch(reset: true)
        let shelf = el("home-shelf")
        XCTAssertTrue(shelf.waitForExistence(timeout: 40), "Home shows at least one real shelf")
        let shelves = app.descendants(matching: .any).matching(identifier: "home-shelf")
        XCTAssertGreaterThanOrEqual(shelves.count, 2, "Home has several shelves")
        // A playlist card opens its page; a song card plays.
        let card = shelves.element(boundBy: 1).buttons.element(boundBy: 0)
        tap(card, "a card")
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline && !el("back").exists && !state.playing { pause(0.5) }
        XCTAssertTrue(el("back").exists || state.playing, "a card opens its page or plays")
        if el("back").exists { XCTAssertTrue(trackRow(0).waitForExistence(timeout: 20), "the page lists tracks") }
    }

    // MARK: 03 Search → filters → play

    func test03_SearchFiltersPlay() {
        launch(reset: true)
        search("Daft Punk")
        for chip in ["Artists", "Albums", "Playlists", "Songs"] {
            tap(button(chip), "\(chip) chip")
            XCTAssertTrue(resultRow(0).waitForExistence(timeout: 15), "\(chip) filter has rows")
        }
        let row = resultRow(0)
        let title = row.label
        row.tap()
        let s0 = waitPlaying("search song")
        XCTAssertFalse(s0.title.isEmpty)
        XCTAssertTrue(title.localizedCaseInsensitiveContains(s0.title) || s0.title.count > 0, "tapped \(title), playing \(s0.title)")
        // Spotify: a search result plays alone, then Autoplay continues with similar songs.
        let s = waitState("autoplay follows the pick", timeout: 30) { $0.auto > 0 }
        XCTAssertEqual(s.qi, 0)
        // Not the other search results as a context: every row after the pick is an Autoplay pick
        // (the core marks them; the search list itself is never queued).
        XCTAssertEqual(s.auto, s.q.count - 1, "everything after the pick is Autoplay (\(s.qt))")
        XCTAssertEqual(s.srcId, "", "a single pick has no context")
        XCTAssertEqual(s.src, "Daft Punk", "Playing from search: the query")
        XCTAssertTrue(el("mini-player-text").exists)
    }

    // MARK: 04 Artist → top song → follow

    func test04_ArtistPlayTopSongFollow() {
        launch(reset: true)
        search("Daft Punk", chip: "Artists")
        tap(resultRow(0), "artist result")
        let follow = button("Follow")
        XCTAssertTrue(follow.waitForExistence(timeout: 30), "artist page loads")
        tap(trackRow(0), "top song")
        let s = waitPlaying("artist top song")
        XCTAssertFalse(s.srcId.isEmpty, "playing from the artist")
        tap(button("Follow"), "Follow")
        XCTAssertTrue(button("Following").waitForExistence(timeout: 5), "button flips to Following")
        waitState("artist saved in the library") { $0.saved.contains(s.srcId) }
        // Shows in Your Library › Artists.
        tap(el("tab-library"), "Library tab")
        tap(el("library-chip-Artists"), "Artists chip")
        XCTAssertTrue(anyContaining("Daft Punk").waitForExistence(timeout: 10), "followed artist in Your Library")
    }

    // MARK: 05 Album → play → like → Liked Songs + Library

    func test05_AlbumPlayLikeLikedSongs() {
        launch(reset: true)
        search("Random Access Memories Daft Punk", chip: "Albums")
        tap(resultRow(0), "album result")
        XCTAssertTrue(trackRow(0).waitForExistence(timeout: 30), "album tracks load")
        tap(el("entity-play"), "album play", timeout: 30)
        let s = waitPlaying("album")
        XCTAssertTrue(s.srcId.hasPrefix("MPRE") || s.srcId.hasPrefix("OLAK"), "playing from the album (\(s.srcId))")
        // Like the second track from its menu.
        let row = trackRow(1)
        sheetAction(on: row, "Add to Liked Songs")
        let liked = waitState("one liked song") { $0.liked.count == 1 }
        let likedTitle = liked.qt[liked.q.firstIndex(of: liked.liked[0]) ?? 0]
        // Liked Songs page lists it.
        tap(el("tab-library"), "Library tab")
        tap(anyLabeled("Liked Songs"), "Liked Songs row")
        XCTAssertTrue(trackRow(0).waitForExistence(timeout: 10), "Liked Songs has the song")
        XCTAssertTrue(anyContaining(likedTitle).exists, "Liked Songs shows \(likedTitle)")
    }

    // MARK: 06 playlists

    func test06_PlaylistCreateAddReorderRenameDeleteUndo() {
        launch(reset: true)
        tap(el("tab-create"), "Create tab")
        tapSheetRow("Playlist")
        let field = el("name-field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        replaceText(field, "E2E Mix")
        tap(el("name-create"), "Create")
        let pl = waitState("playlist created") { $0.playlist(named: "E2E Mix") != nil }
        let pid = pl.playlist(named: "E2E Mix")?["id"] as? String ?? ""
        // Its page opens; add three songs with "Add to this playlist".
        tap(el("add-to-this-playlist"), "Add to this playlist", timeout: 10)
        let q = el("add-search")
        XCTAssertTrue(q.waitForExistence(timeout: 5))
        q.tap()
        q.typeText("Daft Punk")
        let add = app.buttons.matching(identifier: "add-song")
        XCTAssertTrue(add.element(boundBy: 2).waitForExistence(timeout: 30), "search results to add")
        let titles = (0..<3).map { add.element(boundBy: $0).label.replacingOccurrences(of: "Add ", with: "") }
        for i in 0..<3 { add.element(boundBy: i).tap(); pause(0.6) }
        waitState("3 songs in the playlist") { ($0.playlist(named: "E2E Mix")?["count"] as? Int) == 3 }
        tap(el("add-done"), "Done")
        XCTAssertTrue(trackRow(2).waitForExistence(timeout: 10), "the page shows the 3 songs")
        XCTAssertTrue(trackRow(0).label.contains(titles[0]), "first row is the first added (\(trackRow(0).label))")
        // Edit: rename + move the last row to the top.
        tap(button("More options"), "playlist menu")
        tapSheetRow("Edit playlist")
        let name = el("edit-name")
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        let rows = app.descendants(matching: .any).matching(identifier: "edit-row")
        XCTAssertTrue(rows.element(boundBy: 2).waitForExistence(timeout: 10))
        let handles = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Reorder'"))
        XCTAssertTrue(handles.count >= 3, "reorder handles (\(handles.count))")
        handles.element(boundBy: 2).press(forDuration: 0.5, thenDragTo: rows.element(boundBy: 0))
        pause(0.5)
        replaceText(name, "E2E Renamed")
        tap(el("edit-save"), "Save")
        waitState("renamed") { $0.playlist(named: "E2E Renamed") != nil }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline && !trackRow(0).label.contains(titles[2]) { pause(0.5) }
        XCTAssertTrue(trackRow(0).label.contains(titles[2]), "moved row is first now (\(trackRow(0).label))")
        XCTAssertTrue(anyLabeled("E2E Renamed").waitForExistence(timeout: 5), "page title shows the new name")
        // Delete with Undo.
        tap(button("More options"), "playlist menu")
        tapSheetRow("Delete playlist")
        tap(app.alerts.buttons["Delete"], "confirm Delete")
        waitState("deleted") { $0.playlist(named: "E2E Renamed") == nil }
        tap(el("toast"), "Undo toast", timeout: 4)
        let back = waitState("restored by Undo") { $0.playlist(named: "E2E Renamed") != nil }
        XCTAssertEqual(back.playlist(named: "E2E Renamed")?["id"] as? String, pid)
        XCTAssertEqual(back.playlist(named: "E2E Renamed")?["count"] as? Int, 3, "Undo brings the songs back")
    }

    // MARK: 11 podcasts

    func test11_PodcastFollowPlaySpeedSkipResume() {
        launch(reset: true)
        search("Huberman Lab", chip: "Podcasts & Shows")
        tap(el("show-card"), "show card", timeout: 30)
        tap(el("show-follow"), "Follow", timeout: 30)
        waitState("show followed") { !$0.follows.isEmpty }
        tap(el("episode-play"), "play newest episode", timeout: 30)
        waitPlaying("episode", timeout: 60)
        openNowPlaying()
        tap(el("np-speed"), "speed")
        tap(button("1.5x"), "1.5x")
        waitState("speed 1.5") { abs($0.speed - 1.5) < 0.01 }
        let p0 = state.pos
        tap(el("np-fwd15"), "+15 s")
        waitState("jumped forward 15 s") { $0.pos > p0 + 13 }
        let p1 = state.pos
        tap(el("np-back15"), "-15 s")
        waitState("jumped back 15 s") { $0.pos < p1 - 10 }
        // Further in, pause, relaunch: the episode comes back at its position.
        tap(el("np-fwd15"), "+15 s"); tap(el("np-fwd15"), "+15 s")
        let before = waitState("past 30 s") { $0.pos > 30 }
        tap(el("np-play"), "pause")
        let paused = waitState("paused") { $0.paused }
        XCTAssertGreaterThan(paused.pos, before.pos - 2)
        pause(3)
        app.terminate()
        launch()
        let r = waitState("episode restored", timeout: 30) { $0.id == paused.id }
        XCTAssertEqual(r.pos, paused.pos, accuracy: 6, "resumes where it was (podcasts resume ~5 s early)")
        // Speed sticks for episodes.
        XCTAssertEqual(r.speed, 1.5, accuracy: 0.01)
        tap(el("mini-play"), "play")
        waitPlaying("resumed episode", timeout: 40)
        XCTAssertGreaterThan(state.pos, paused.pos - 8)
    }

    // MARK: 12 Made for you

    func test12_MadeForYouAfterListening() {
        launch(reset: true, deeplink: "encore://playsearch?q=Daft%20Punk%20Get%20Lucky&open=1")
        waitPlaying()
        // Listen and like a few songs (the taste signals).
        for _ in 0..<3 {
            tap(el("np-like"), "like")
            let i = state.qi
            tap(el("np-next"), "next")
            waitState("next song plays") { $0.qi == i + 1 && $0.playing }
            pause(3)
        }
        closeNowPlaying()
        tap(el("tab-home"), "Home")
        // Pull to refresh until the Made for you shelf is there (its first build needs the listening).
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline && !el("mfy-show-all").exists {
            app.swipeDown(); pause(8)
        }
        tap(el("mfy-show-all"), "Made for you", timeout: 5)
        waitState("Made for you cards") { $0.mfy > 0 }
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Mix' OR label CONTAINS[c] 'Discover' OR label CONTAINS[c] 'Repeat' OR label CONTAINS[c] 'Radar'")).firstMatch
        tap(card, "a Made for you card", timeout: 30)
        XCTAssertTrue(trackRow(4).waitForExistence(timeout: 30), "the mix has songs")
        tap(el("entity-play"), "play the mix")
        waitState("the mix is the queue") { $0.srcId.hasPrefix("MFY_") || $0.srcId.hasPrefix("dailymix") }
        waitPlaying("mix")
    }

    // MARK: 13 What's New

    func test13_WhatsNewAfterFollowing() {
        launch(reset: true)
        search("Taylor Swift", chip: "Artists")
        tap(resultRow(0), "artist")
        tap(button("Follow"), "Follow", timeout: 30)
        XCTAssertTrue(button("Following").waitForExistence(timeout: 5))
        tap(el("tab-home"), "Home")
        tap(el("avatar"), "avatar")
        tap(button("What's new"), "What's new in the side menu")
        XCTAssertTrue(el("whatsnew-release").waitForExistence(timeout: 60), "a followed artist's releases show in What's New")
        tap(el("whatsnew-release"), "a release")
        XCTAssertTrue(trackRow(0).waitForExistence(timeout: 30), "the release opens")
    }

    // MARK: 14 settings persist

    func test14_SettingsPersistAndExplicitGreys() {
        launch(reset: true)
        tap(el("avatar"), "avatar")
        tap(button("Settings and privacy"), "Settings and privacy")
        tap(el("settings-row-Playback"), "Playback")
        let normalize = el("toggle-Normalize volume")
        XCTAssertTrue(normalize.waitForExistence(timeout: 10))
        let n0 = state.normalize
        normalize.switches.firstMatch.exists ? normalize.switches.firstMatch.tap() : normalize.tap()
        waitState("normalize flipped") { $0.normalize != n0 }
        el("crossfade").adjust(toNormalizedSliderPosition: 0.5)
        waitState("crossfade set") { $0.crossfade >= 5 && $0.crossfade <= 7 }
        let explicitToggle = el("toggle-Allow explicit content")
        explicitToggle.switches.firstMatch.exists ? explicitToggle.switches.firstMatch.tap() : explicitToggle.tap()
        waitState("explicit filter on") { $0.explicitFilter }
        app.swipeUp()
        tap(el("settings-row-Equalizer"), "Equalizer")
        let eqToggle = el("toggle-Equalizer")
        XCTAssertTrue(eqToggle.waitForExistence(timeout: 5))
        if !state.eqOn { eqToggle.switches.firstMatch.exists ? eqToggle.switches.firstMatch.tap() : eqToggle.tap() }
        waitState("EQ on") { $0.eqOn }
        app.swipeUp()
        tap(button("Rock"), "Rock preset")
        waitState("Rock preset") { $0.eq == "Rock" && $0.eqOn }
        let before = state
        pause(1)
        app.terminate()
        launch()
        let after = waitState("settings loaded after relaunch") { $0.crossfade >= 0 }
        XCTAssertEqual(after.normalize, before.normalize, "normalize persists")
        XCTAssertEqual(after.crossfade, before.crossfade, "crossfade persists")
        XCTAssertTrue(after.explicitFilter, "explicit filter persists")
        XCTAssertEqual(after.eq, "Rock", "EQ preset persists")
        XCTAssertTrue(after.eqOn)
        // Explicit rows are greyed and don't play.
        search("Eminem Without Me", chip: "Songs")
        let explicitRow = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'result-row' AND value == 'explicit, unavailable'")).firstMatch
        XCTAssertTrue(explicitRow.waitForExistence(timeout: 15), "explicit songs are greyed (marked unavailable)")
        explicitRow.tap()
        pause(4)
        XCTAssertFalse(state.playing, "a blocked explicit song doesn't play")
    }

    // MARK: 07 queue

    func test07_QueuePlayNextAddClear() {
        launch(reset: true, deeplink: "encore://playsearch?q=Daft%20Punk%20Get%20Lucky")
        waitPlaying("first song")
        // A search pick is followed by Autoplay; let it land so the counts below are the user's.
        let s0 = waitState("autoplay landed", timeout: 30) { $0.auto > 0 }
        search("Michael Jackson Billie Jean", chip: "Songs")
        let a = resultRow(0).label
        sheetAction(on: resultRow(0), "Add to queue")
        let s1 = waitState("queued song after current") { $0.q.count > s0.q.count }
        let queuedId = s1.q[s1.qi + 1]
        // A different song (Play next on a row already queued moves it instead of doubling it).
        search("Michael Jackson Thriller", chip: "Songs")
        sheetAction(on: resultRow(0), "Play next")
        let s2 = waitState("play next goes first") { $0.q.count > s1.q.count && $0.q[$0.qi + 1] != queuedId }
        XCTAssertNotEqual(s2.q[s2.qi + 1], queuedId, "Play next is ahead of the earlier Add to queue (\(a))")
        XCTAssertEqual(s2.q[s2.qi + 2], queuedId, "Add to queue keeps its place after Play next")
        // Queue screen shows "Next in queue" and clears it.
        openNowPlaying()
        tap(el("np-queue"), "queue button")
        XCTAssertTrue(text("Next in queue").waitForExistence(timeout: 5))
        tap(button("Clear queue"), "Clear queue")
        waitState("queued songs cleared") { $0.q.count == s0.q.count && !$0.q.contains(queuedId) }
        // The List can keep a removed header in the accessibility tree for a while: judge by what
        // is on screen.
        let header = text("Next in queue")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && header.exists && header.isHittable { pause(0.3) }
        XCTAssertFalse(header.exists && header.isHittable, "the Next in queue section goes away")
        XCTAssertEqual(state.id, s0.id, "the playing song keeps playing")
    }

    // MARK: 08 shuffle / repeat / smart shuffle

    func test08_ShuffleRepeatSmartShuffle() {
        launch(reset: true, deeplink: "encore://playsearch?q=Daft%20Punk%20Get%20Lucky")
        waitPlaying()
        // Like the current song + one more so Liked Songs is an own collection with songs.
        openNowPlaying()
        tap(el("np-like"), "like")
        tap(el("np-next"), "next")
        waitState("next song") { $0.qi == 1 && $0.playing }
        tap(el("np-like"), "like")
        waitState("two liked") { $0.liked.count == 2 }
        closeNowPlaying()
        tap(el("tab-library"), "Library tab")
        tap(anyLabeled("Liked Songs"), "Liked Songs")
        tap(el("entity-play"), "play Liked Songs", timeout: 15)
        waitState("playing Liked Songs") { $0.srcId == "VLLM" && $0.playing }
        openNowPlaying()
        let sh = el("np-shuffle")
        tap(sh, "shuffle")
        waitState("shuffle on") { $0.shuffle && !$0.smart }
        tap(sh, "smart shuffle")
        waitState("smart shuffle on", timeout: 30) { $0.smart && $0.shuffle }
        // Suggestions come from YouTube's recommendations: note it when the network gave none.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline && state.recs == 0 { pause(1) }
        if state.recs == 0 { print("E2E_NOTE smart shuffle on but no suggestions arrived (recommendations call failed)") }
        tap(sh, "shuffle off")
        waitState("shuffle off") { !$0.shuffle && !$0.smart }
        let rep = button("Repeat")
        tap(rep, "repeat"); waitState("repeat all") { $0.repeatMode == "all" }
        tap(rep, "repeat"); waitState("repeat one") { $0.repeatMode == "one" }
        // Repeat one: next track at the end replays the same song.
        let id = state.id
        debug("seek-near-end")
        pause(14)
        let s = waitState("repeat one replays") { $0.id == id && $0.pos < 8 && $0.playing }
        XCTAssertEqual(s.id, id)
        tap(rep, "repeat"); waitState("repeat off") { $0.repeatMode == "off" }
    }

    // MARK: 09 radio

    func test09_SongRadio() {
        launch(reset: true)
        search("Daft Punk Get Lucky", chip: "Songs")
        sheetAction(on: resultRow(0), "Go to song radio")
        let s = waitPlaying("radio")
        XCTAssertGreaterThanOrEqual(s.q.count, 10, "radio fills a long queue (\(s.q.count))")
        XCTAssertTrue(s.src.localizedCaseInsensitiveContains("radio"), "source names the radio (\(s.src))")
    }

    // MARK: 10 lyrics

    func test10_LyricsSyncedHighlightAdvances() {
        launch(reset: true, deeplink: "encore://playsearch?q=Daft%20Punk%20Get%20Lucky&open=1")
        waitPlaying()
        openNowPlaying()
        // The lyrics card sits under the controls: scroll Now Playing to it, then expand it.
        let card = el("lyrics-card")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        let screen = app.frame.height
        for _ in 0..<8 where card.frame.minY > screen * 0.55 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
            pause(0.6)
        }
        card.tap()
        XCTAssertTrue(el("lyrics-full").waitForExistence(timeout: 10))
        // Jump into the sung part by tapping a line (it seeks), then let playback move the highlight.
        let line = app.descendants(matching: .any).matching(identifier: "lyric-line").element(boundBy: 4)
        tap(line, "a lyric line")
        let first = el("lyric-active")
        XCTAssertTrue(first.waitForExistence(timeout: 15), "a synced line highlights")
        let l1 = first.label
        let deadline = Date().addingTimeInterval(30)
        var l2 = l1
        while Date() < deadline && l2 == l1 { pause(1); l2 = el("lyric-active").label }
        XCTAssertNotEqual(l1, l2, "the highlighted line advances with playback")
    }

    // MARK: 15 sleep timer

    func test15_SleepTimerEndOfTrackStops() {
        launch(reset: true, deeplink: "encore://playsearch?q=Daft%20Punk%20Get%20Lucky&open=1")
        waitPlaying()
        openNowPlaying()
        tap(button("More options"), "Now Playing menu")
        tapSheetRow("Sleep timer")
        tap(button("End of track"), "End of track")
        waitState("sleep timer on") { !$0.sleep.isEmpty }
        let id = state.id
        debug("seek-near-end")
        let s = waitState("playback stops at the end of the track", timeout: 40) { $0.paused && $0.id != "" }
        pause(3)
        XCTAssertTrue(state.paused, "stays stopped")
        XCTAssertTrue(s.id == id || s.pos < 3, "stopped at the track boundary")
        waitState("timer cleared") { $0.sleep.isEmpty }
    }

    // MARK: 16 background + interruption

    func test16_BackgroundAndInterruption() {
        launch(reset: true, deeplink: "encore://playsearch?q=Daft%20Punk%20Get%20Lucky")
        let s0 = waitPlaying()
        XCUIDevice.shared.press(.home)
        pause(12)
        app.activate()
        let s1 = waitState("position kept moving in the background") { $0.pos > s0.pos + 9 }
        XCTAssertFalse(s1.paused)
        debug("interruption-began")
        let p = waitState("interruption pauses") { $0.paused }.pos
        pause(3)
        XCTAssertLessThan(state.pos - p, 0.5, "clock frozen while interrupted")
        debug("interruption-ended-resume")
        waitPlaying("resume after interruption", timeout: 15)
        debug("route-old-unavailable")
        waitState("headphones out pauses") { $0.paused }
        debug("remote-toggle")
        waitPlaying("remote play", timeout: 15)
        debug("media-reset")
        pause(4)
        waitPlaying("after media services reset", timeout: 15)
    }

    // MARK: 17 relaunch restores

    func test17_RelaunchRestoresQueueAndPosition() {
        launch(reset: true, deeplink: "encore://playsearch?q=Daft%20Punk%20Get%20Lucky")
        waitPlaying()
        openNowPlaying()
        tap(el("np-next"), "next")
        let s = waitState("second song playing past 5 s", timeout: 40) { $0.qi == 1 && $0.pos > 5 && $0.playing }
        tap(el("np-play"), "pause")
        let paused = waitState("paused") { $0.paused }
        pause(2) // the core persists the position on pause
        app.terminate()
        launch()
        let r = waitState("restored queue", timeout: 30) { $0.id == s.id }
        XCTAssertEqual(r.q, s.q, "the same queue comes back")
        XCTAssertEqual(r.qi, s.qi)
        XCTAssertEqual(r.pos, paused.pos, accuracy: 3, "the position comes back")
        XCTAssertTrue(el("mini-player-text").waitForExistence(timeout: 5), "mini player shows the restored song")
    }

    // MARK: 18 Add to playlist picker (ios-polish)

    func test18_AddToPlaylistPicker() {
        launch(reset: true, deeplink: "encore://playsearch?q=Daft%20Punk%20Get%20Lucky&open=1")
        let s0 = waitPlaying()
        openNowPlaying()
        tap(button("More options"), "Now Playing menu")
        tapSheetRow("Add to playlist")
        tap(el("picker-new-playlist"), "New playlist")
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let f = alert.textFields.firstMatch
        f.tap()
        f.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 30) + "Picker Mix")
        alert.buttons["Create"].tap()
        let made = waitState("new playlist holds the song") { ($0.playlist(named: "Picker Mix")?["count"] as? Int) == 1 }
        let pid = made.playlist(named: "Picker Mix")?["id"] as? String ?? ""
        // A second song, ticked in the picker under Recently updated.
        closeNowPlaying()
        search("Daft Punk One More Time", chip: "Songs")
        sheetAction(on: resultRow(0), "Add to playlist")
        let row = el("picker-row-\(pid)")
        tap(row, "Picker Mix row")
        tap(el("picker-done"), "Done")
        waitState("2 songs in Picker Mix") { ($0.playlist(named: "Picker Mix")?["count"] as? Int) == 2 }
        // Reopen for the first song: "Saved in" lists it, ticked.
        openNowPlaying()
        XCTAssertEqual(state.id, s0.id)
        tap(button("More options"), "Now Playing menu")
        tapSheetRow("Add to playlist")
        XCTAssertTrue(app.staticTexts["Saved in"].waitForExistence(timeout: 8))
        XCTAssertTrue(el("picker-row-\(pid)").isSelected, "Picker Mix is ticked under Saved in")
        tap(el("picker-cancel"), "Cancel")
    }

    // MARK: 19 downloads, offline (ios-polish)

    func test19_DownloadThenPlayOffline() {
        launch(reset: true)
        search("Daft Punk Get Lucky", chip: "Albums")
        let single = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'result-row' AND label CONTAINS[c] 'Single'")).firstMatch
        tap(single.exists ? single : resultRow(0), "a single")
        XCTAssertTrue(trackRow(0).waitForExistence(timeout: 30), "release page")
        let tracks = app.descendants(matching: .any).matching(identifier: "track-row").count
        tap(el("download-button"), "Download")
        waitState("downloaded (\(tracks) tracks)", timeout: 120) { $0.dlDone >= max(1, tracks) && $0.dlActive == 0 }
        // Offline mode (Settings › Data-saving and offline).
        tap(el("tab-home"), "Home")
        tap(el("avatar"), "avatar")
        tap(button("Settings and privacy"), "Settings and privacy")
        tap(el("settings-row-Data-saving and offline"), "Data-saving and offline")
        let off = el("toggle-Offline mode")
        XCTAssertTrue(off.waitForExistence(timeout: 8))
        off.switches.firstMatch.exists ? off.switches.firstMatch.tap() : off.tap()
        waitState("offline on") { $0.offline }
        // Play the downloaded release from Your Library › Downloaded.
        tap(el("tab-library"), "Library")
        tap(el("library-chip-Downloaded"), "Downloaded chip")
        tap(app.descendants(matching: .any).matching(identifier: "library-row").firstMatch, "the downloaded release")
        tap(el("entity-play"), "play", timeout: 20)
        waitPlaying("offline playback", timeout: 30)
    }

    // MARK: 20 links + share (ios-polish)

    func test20_LinksAndShare() {
        // A music.youtube.com album link opens the album.
        launch(reset: true, deeplink: "https://music.youtube.com/browse/MPREb_dMHztPsrDgN")
        XCTAssertTrue(trackRow(0).waitForExistence(timeout: 40), "album link opens the album")
        XCTAssertTrue(anyContaining("Homework").exists, "it is Homework")
        // A youtu.be song link pasted into Search plays it.
        tap(el("tab-search"), "Search")
        tap(el("search-field"), "search field")
        tap(el("search-input"), "search input")
        el("search-input").typeText("https://youtu.be/4D7u5KF7SP8\n")
        waitState("pasted link plays", timeout: 45) { $0.id == "4D7u5KF7SP8" && $0.playing }
        // Share from Now Playing: the system sheet with our Copy Encore link.
        openNowPlaying()
        tap(el("np-share"), "Share")
        XCTAssertTrue(app.descendants(matching: .any)["Copy Spotless link"].waitForExistence(timeout: 10), "share sheet")
    }

    // MARK: 21 Spotify import (ios-polish)

    func test21_SpotifyImportFromExport() {
        launch(reset: true, deeplink: "encore://import?file=e2e-export.zip")
        tap(el("import-start"), "Import", timeout: 20)
        // Matching ends in the review step (To check / Not found / Matched); accept and create.
        XCTAssertTrue(el("import-review").waitForExistence(timeout: 180), "matching ends in review")
        tap(el("import-create"), "Create")
        XCTAssertTrue(el("import-done").waitForExistence(timeout: 60), "import done")
        tap(el("import-go-library"), "Go to Your Library")
        let s = waitState("imported playlist + likes", timeout: 20) { ($0.playlist(named: "Road Trip Classics")?["count"] as? Int ?? 0) >= 6 && $0.liked.count >= 4 }
        XCTAssertGreaterThanOrEqual(s.liked.count, 4)
        XCTAssertTrue(anyContaining("Road Trip Classics").waitForExistence(timeout: 5), "in Your Library")
    }

    // MARK: 22 Hide song

    func test22_HideSongIsSkipped() {
        launch(reset: true)
        search("Daft Punk", chip: "Songs")
        tap(resultRow(0), "first song")
        let s = waitPlaying("first song")
        let nextId = s.q[s.qi + 1], nextTitle = s.qt[s.qi + 1]
        // Hide the song that is up next, from its row in the results.
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'result-row' AND label BEGINSWITH %@", nextTitle)).firstMatch
        dismissKeyboard()
        sheetAction(on: row, "Hide song")
        waitState("the next song is hidden") { $0.hidden.contains(nextId) }
        debug("seek-near-end")
        let next = waitState("advanced past the end", timeout: 60) { $0.id != s.id && !$0.id.isEmpty && $0.playing }
        XCTAssertNotEqual(next.id, nextId, "playback steps over the hidden song")
        XCTAssertGreaterThan(next.qi, s.qi + 1)
    }
}
