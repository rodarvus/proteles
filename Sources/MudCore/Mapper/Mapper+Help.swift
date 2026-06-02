import Foundation

/// Phase 8 of the mapper-fidelity work: the sectioned `mapper help`, ported
/// verbatim from the reference `aard_GMCP_mapper.xml` `OnHelp()`. `mapper help`
/// shows the index; `mapper help <section>` shows one section; `mapper help all`
/// shows every section; `mapper help search <txt>` lists matching help lines.
extension Mapper {
    private static let helpHeaderTitle = "                              [GMCP Mapper Help]"
    private static let helpBorder =
        "+---------------------------------------------------------------------------+"

    /// `mapper help [section|all|search <txt>]`.
    func helpOutput(_ arg: String) -> [ScriptEffect] {
        var out: [ScriptEffect] = [Self.note(""), Self.note(Self.helpHeaderTitle), Self.note(Self.helpBorder)]
        let topic = arg.trimmingCharacters(in: .whitespaces)
        if topic.isEmpty {
            out += Self.helpIndex.map { Self.note($0) }
        } else if topic == "all" {
            for key in Self.sectionOrder {
                out += Self.sectionLines(key).map { Self.note($0) }
            }
        } else if Self.sectionBodies[topic] != nil {
            out += Self.sectionLines(topic).map { Self.note($0) }
        } else if topic.lowercased().hasPrefix("search ") {
            out += Self.helpSearch(String(topic.dropFirst("search ".count)))
        } else {
            out += Self.helpIndex.map { Self.note($0) } // badnews → the index
        }
        return out
    }

    /// `show_help`: a blank line, the section header, a blank line, then the body.
    private static func sectionLines(_ key: String) -> [String] {
        guard let header = sectionHeaders[key], let body = sectionBodies[key] else { return [] }
        return ["", header, ""] + body.components(separatedBy: "\n")
    }

    /// A help line with the search term highlighted — the matched runs render in
    /// the error colour against the note colour (the reference colour-highlights
    /// the match). Case-insensitive; an empty needle falls back to a plain note.
    static func highlightedNote(_ line: String, match needle: String) -> ScriptEffect {
        guard !needle.isEmpty else { return note(line) }
        var segments: [NoteSegment] = []
        var cursor = line.startIndex
        while let range = line.range(of: needle, options: .caseInsensitive, range: cursor..<line.endIndex) {
            if range.lowerBound > cursor {
                segments.append(NoteSegment(
                    text: String(line[cursor..<range.lowerBound]), foreground: MapperOutput.noteColour
                ))
            }
            segments.append(NoteSegment(text: String(line[range]), foreground: MapperOutput.errorColour))
            cursor = range.upperBound
        }
        if cursor < line.endIndex {
            segments.append(NoteSegment(text: String(line[cursor...]), foreground: MapperOutput.noteColour))
        }
        return .colourNote(segments)
    }

    /// `mapper help search <txt>`: list help lines containing the pattern under
    /// their section headers, with the matched term highlighted.
    private static func helpSearch(_ pattern: String) -> [ScriptEffect] {
        let needle = pattern.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return helpIndex.map { note($0) } }
        var out: [ScriptEffect] = [note(""), highlightedNote("Searching help for: \(needle)", match: needle)]
        let lowered = needle.lowercased()
        for key in sectionOrder {
            guard let body = sectionBodies[key], let header = sectionHeaders[key] else { continue }
            let matches = body.components(separatedBy: "\n").filter {
                !$0.isEmpty && !$0.contains("--------") && $0.lowercased().contains(lowered)
            }
            if !matches.isEmpty {
                out.append(note(""))
                out.append(note(header))
                for match in matches {
                    out.append(highlightedNote(match, match: needle))
                }
            }
        }
        return out
    }

    private static let sectionOrder = [
        "config", "exits", "portals", "searching", "exploring", "moving", "utils"
    ]

    private static let helpIndex = """
                               Mapper Help Index
    =============================================================================
     mapper help               --> Show this list
     mapper help all           --> Show the entire list of all mapper commands
    -----------------------------------------------------------------------------
     mapper help config        --> Commands for configuring the mapper
     mapper help exits         --> Commands for managing exits
     mapper help portals       --> Commands for managing portals
     mapper help searching     --> Commands for finding rooms
     mapper help exploring     --> Commands to aid exploring
     mapper help moving        --> Commands for moving between rooms
     mapper help utils         --> Other utilitarian commands
     mapper help search <txt>  --> Searches through help lines looking for a
                                   particular word or phrase.
    =============================================================================
    """.components(separatedBy: "\n")

    private static let sectionHeaders: [String: String] = [
        "config": "===== CONFIGURATION =============>",
        "utils": "===== UTILITIES =================>",
        "exits": "===== EXIT ACTIONS ==============>",
        "portals": "===== PORTAL ACTIONS ============>",
        "searching": "===== SEARCHING =================>",
        "exploring": "===== EXPLORING =================>",
        "moving": "===== MOVING ====================>"
    ]

    // swiftlint:disable line_length
    private static let sectionBodies: [String: String] = [
        "config": """
        mapper quicklist [on/off]      --> ON will cause search results to display
                                         > much faster, but the results will not be
                                         > sorted by distance (default is on)
        mapper shownotes [on/off]      --> ON will cause room notes to display
                                         > automatically upon entering (default is on)
        mapper compact [on/off]        --> ON will make it so no blank lines are
                                         > displayed by the mapper (default is off)
        mapper backups <off/on>        --> Turn off or on automatic database backups
                                         > The default setting is on
        mapper backups quiet           --> Toggle whether messages are shown during
                                         > backups
        mapper backups [un]compressed  --> Turn off or on database backup compression
                                         > The default setting is uncompressed (off)
        mapper help                    --> This help
                                         > (or click the "?" button on the top right)
        mapper zoom out                --> Zoom out
        mapper zoom in                 --> Zoom in
        mapper hide                    --> Hide map
        mapper show                    --> Show map
        mapper updown                  --> Toggle up/down exit drawing
        mapper underlines              --> Toggle underlining of clickable links
        mapper database                --> Print the name of the map database file.
        mapper set database <new_name> --> Change the map database file.
        """,
        "utils": """
        mapper backup                  --> Create new archived backup of your map
                                         > database in a db_backups directory,
                                         > preserving a few prior backups
        mapper addnote                 --> Add a new note to the current room
        mapper addnote <note>          --> Ditto, but skips the dialog
        mapper delete note             --> Delete the note in the current room
                                         > without using the addnote dialog
        mapper purgezone <area>        --> Delete an area from the map database
        mapper purgeroom               --> Delete the current room from the database
        mapper ignore mismatch <true/false> --> Don't change the room in the database
                                              > if only the exits are "wrong"
        """,
        "exits": """
        mapper cexits                  --> List known custom exits
        mapper cexits <here/area>      --> List known custom exits only in this or
                                         > another area
        mapper cexit <command>         --> Follow and link a custom exit
                                         > (ex: 'mapper cexit ride bucket')
                                         > To insert a pause during execution
                                         > of the cexit, use wait(<seconds>) as one
                                         > or more of the cexit moves
                                         > To stack commands use ;; as separator
                                         > to get around the line break parser
                                         > (ex: 'mapper cexit open south;;south')
        mapper delete exits from <room> --> Delete exits from the given room ID to
                                             the current room.
        mapper delete exits to <room>   --> Delete exits to the given room ID from
                                             the current room.
        mapper delete cexits           --> Remove the custom exits from this room
        mapper purge cexits            --> Remove all custom exits in database
        mapper purge cexits area       --> Remove all custom exits in the area
        mapper cexit_wait <seconds>    --> Wait this number of seconds instead of
                                         > the standard 2 when constructing the next
                                         > cexit (between 2 and 40)
        mapper lockexit                --> Bring up the exit level-locking dialog
                                         > for the current room.

        There is also \n'mapper fullcexit {<command>} <source> <destination> <level> [quiet]'\nwhich lets you set all cexit aspects in one command without running it.

        """,
        "portals": """
        mapper portals                 --> List known hand-held portals
        mapper portals here/<area>     --> List known hand-held portals only to this
                                         > or another area (by area keyword).
        mapper portal <command>        --> Link a handheld portal to the current
                                         > room as a special exit from everwhere else
                                         > (ex: 'mapper portal recall' at recall).
                                         > To stack commands use ;; as separator
                                         > to get around the line-break parser
                                         > (ex: 'mapper portal hold amulet;;enter').

        There is also \n'mapper fullportal {<command>} {<room_id>} <level> [quiet]'\nwhich lets you set all portal aspects in one command without being there.

        +---- NORECALL/NOPORTAL ROOM ASSISTANCE -------------------------------------+
        mapper portalrecall <index>    --> Flag/unflag a portal as using a recall or
                                         > home command, to avoid using it in
                                         > identified norecall rooms.
                                         > Find the indices with 'mapper portals'
        mapper bounceportal <index>    --> Specifies which non-recall mapper portal
                                         > to bounce through when the path calculation
                                         > wants to recall or home from a
                                         > portal-friendly norecall room. For this to
                                         > work properly you must indicate which mapper
                                         > portals use recall or home with the
                                         > portalrecall command listed above.
                                         > Find the indices with 'mapper portals'
        mapper bouncerecall <index>    --> Specifies which home/recall mapper portal
                                         > to bounce through when the path calculation
                                         > wants to portal from a recall-friendly
                                         > noportal room. You may only choose a portal
                                         > that has been marked as being a recall
                                         > portal using the portalrecall command listed
                                         > above.
                                         > Find the indices with 'mapper portals'
        mapper bounceportal            --> Display the current bounce portal
        mapper bouncerecall            --> Display the current bounce recall
        mapper bounceportal clear      --> Clear the current bounce portal
        mapper bouncerecall clear      --> Clear the current bounce recall
        +----------------------------------------------------------------------------+
        mapper noportal <id> [true/false] --> Manually set noportal flag
        mapper norecall <id> [true/false] --> Manually set norecall flag
        +----------------------------------------------------------------------------+

        mapper portallevel <ind> <lvl> [quiet] --> Change the level lock on a portal.
                                                   > Find indices with 'mapper portals'.
                                                   > Do not manually account for tiers.
                                                   > Adding 'quiet' means no output.
        mapper delete portal <command> --> Remove the specified hand-held portal alias
        mapper delete portal #<index>  --> Remove a hand-held portal by its index
                                         > Find the indices with 'mapper portals'
        mapper change portal {<old cmd>} {<new cmd>} --> Change a portal command.
        mapper change portal #<index> {<new cmd>}    --> Change a portal command
                                                       > by index.
        mapper purge portals           --> Remove all hand-held portal aliases
        """,
        "searching": """
        mapper area <text>             --> Full-text search limited to the current zone
        mapper find <text>             --> Full-text search the whole database
        mapper list <text>             --> Find rooms without the known-path limits
                                         > of "area" and "find"

        mapper notes                   --> Show nearby rooms that you marked with notes
        mapper notes <here/area>       --> Ditto
        mapper shops                   --> Show all shops/banks
        mapper shops <here/area>       --> Ditto
        mapper train                   --> Show all trainers
        mapper train <here/area>       --> Ditto
        mapper quest                   --> Show all quest-givers
        mapper quest <here/area>       --> Ditto

        mapper next                    --> Visit the next room in the most recent
                                         > list of results.
        mapper next <index>            --> Ditto, but skip to the given result index.
        mapper where <room id>         --> Show directions to a room number
        """,
        "exploring": """
        mapper thisroom                --> Show details about the current room
        mapper showroom <room id>      --> Draw the map as if you were standing in
                                         > a different room
        mapper areas                   --> Show a list of all mapped areas
        mapper areas <name>            --> Show a list of mapped areas partially
                                         > matching <name>
        mapper unmapped                --> List unmapped exit counts for known areas
        mapper unmapped <here/area>    --> List unmapped exits in this or another area
        """,
        "moving": """
        mapper goto <room id>          --> Run to a room by its room number
        mapper walkto <room id>        --> Run to a room by its room number without
                                         > using any mapper portals
        mapper resume                  --> Initiate a new run to the previous target
        """
    ]
    // swiftlint:enable line_length
}
