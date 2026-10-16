#!/usr/bin/env wish
# ytdl.tcl — YouTube Download Queue Manager
# Requires: Tcl/Tk 8.5+

package require Tk

# ---------------------------------------------------------------------------
# Configuration / Persistence paths
# ---------------------------------------------------------------------------
set SCRIPT_DIR  [file dirname [file normalize [info script]]]
set CONFIG_FILE [file join $SCRIPT_DIR ytdl.ini]
set QUEUE_FILE  [file join $env(HOME) .ytdl_queue]

# ---------------------------------------------------------------------------
# Application state
# ---------------------------------------------------------------------------
# queue: list of dicts, each dict has keys: id url status output
#   status: pending | downloading | done | error
set ::queue {}
set ::next_id 1
set ::DEFAULT_DOWNLOAD_CMD "yt-dlp_linux --cookies-from-browser vivaldi --js-runtime node -P <target_dir> <url>"
set ::download_cmd $::DEFAULT_DOWNLOAD_CMD
set ::target_dir   [file join $env(HOME) Videos]  ;# output directory for downloads
set ::version "0.3.1"
set ::active_pipe ""     ;# channel of currently running subprocess
set ::active_id  ""      ;# id of currently downloading item

# ---------------------------------------------------------------------------
# Persistence helpers
# ---------------------------------------------------------------------------
proc config_save {} {
    set fd [open $::CONFIG_FILE w]
    puts $fd "cmd=$::download_cmd"
    puts $fd "target_dir=$::target_dir"
    close $fd
    ui_show_saved_notice
}

proc ui_show_saved_notice {} {
    if {![info exists ::W(statussaved)]} return
    $::W(statussaved) configure -text "configuration saved..."
    after 3000 { $::W(statussaved) configure -text "" }
}

proc config_load {} {
    if {![file exists $::CONFIG_FILE]} return
    set fd [open $::CONFIG_FILE r]
    while {[gets $fd line] >= 0} {
        set line [string trim $line]
        if {$line eq "" || [string match "#*" $line]} continue
        if {[regexp {^([^=]+)=(.*)$} $line -> key val]} {
            switch $key {
                cmd        { set ::download_cmd $val }
                target_dir { set ::target_dir $val }
            }
        }
    }
    close $fd
}

proc queue_save {} {
    set fd [open $::QUEUE_FILE w]
    foreach item $::queue {
        dict with item {
            # Reset any in-progress item to pending on save (crash recovery)
            set save_status $status
            if {$save_status eq "downloading"} { set save_status "pending" }
            # Store only metadata, not the live output buffer
            puts $fd [list $id $url $save_status]
        }
    }
    close $fd
}

proc queue_load {} {
    if {![file exists $::QUEUE_FILE]} return
    set fd [open $::QUEUE_FILE r]
    while {[gets $fd line] >= 0} {
        set line [string trim $line]
        if {$line eq ""} continue
        lassign $line id url status
        # Validate status — downloading at save time means it was interrupted
        if {$status ni {pending done error}} { set status pending }
        set item [dict create id $id url $url status $status output ""]
        lappend ::queue $item
        # Keep next_id beyond any loaded id
        if {$id >= $::next_id} { set ::next_id [expr {$id + 1}] }
    }
    close $fd
}

# ---------------------------------------------------------------------------
# Queue operations
# ---------------------------------------------------------------------------
proc queue_add {url} {
    set url [string trim $url]
    if {$url eq ""} return
    set id $::next_id
    incr ::next_id
    set item [dict create id $id url $url status pending output ""]
    lappend ::queue $item
    queue_save
    ui_queue_refresh
    worker_kick
}

proc queue_find_index {id} {
    set i 0
    foreach item $::queue {
        if {[dict get $item id] == $id} { return $i }
        incr i
    }
    return -1
}

proc queue_update {id args} {
    set idx [queue_find_index $id]
    if {$idx < 0} return
    set item [lindex $::queue $idx]
    foreach {key val} $args {
        dict set item $key $val
    }
    lset ::queue $idx $item
}

proc queue_remove_selected {} {
    set sel [$::W(qlist) curselection]
    if {$sel eq ""} return
    set idx [lindex $sel 0]
    set item [lindex $::queue $idx]
    set id [dict get $item id]
    # Don't remove actively downloading item
    if {$id == $::active_id} {
        tk_messageBox -type ok -icon warning \
            -message "Cannot remove an item that is currently downloading."
        return
    }
    set ::queue [lreplace $::queue $idx $idx]
    queue_save
    ui_queue_refresh
    ui_output_clear
}

proc queue_clear_done {} {
    set to_clear 0
    foreach item $::queue {
        if {[dict get $item status] in {done error}} {
            incr to_clear
        }
    }
    if {$to_clear == 0} return
    set answer [tk_messageBox \
        -type yesno \
        -icon question \
        -title "Clear queue" \
        -message "Remove $to_clear done/error item(s) from the queue?"]
    if {$answer ne "yes"} return
    set new_queue {}
    foreach item $::queue {
        if {[dict get $item status] ni {done error}} {
            lappend new_queue $item
        }
    }
    set ::queue $new_queue
    queue_save
    ui_queue_refresh
    ui_output_clear
}

# ---------------------------------------------------------------------------
# Async download worker
# ---------------------------------------------------------------------------
proc worker_kick {} {
    # Already running?
    if {$::active_pipe ne ""} return
    # Find first pending item
    foreach item $::queue {
        if {[dict get $item status] eq "pending"} {
            worker_start [dict get $item id] [dict get $item url]
            return
        }
    }
}

proc worker_start {id url} {
    set ::active_id $id
    queue_update $id status downloading output ""
    ui_queue_refresh
    ui_output_show $id

    # Build the command: substitute <url> and <directory> placeholders.
    # If neither is present, fall back to the legacy "-P <dir> <url>" convention.
    if {[string first "<url>" $::download_cmd] >= 0 || [string first "<target_dir>" $::download_cmd] >= 0} {
        set cmd [string map [list "<url>" [list $url] "<target_dir>" [list $::target_dir]] $::download_cmd]
    } else {
        set cmd "$::download_cmd -P [list $::target_dir] [list $url]"
    }
    if {[catch {open "|$cmd 2>@1" r} pipe]} {
        # Command not found or other launch error
        queue_update $id status error output "Failed to start: $pipe"
        set ::active_pipe ""
        set ::active_id  ""
        queue_save
        ui_queue_refresh
        ui_output_show $id
        worker_kick
        return
    }
    set ::active_pipe $pipe
    fconfigure $pipe -blocking 0 -buffering line
    fileevent $pipe readable [list worker_read $id $pipe]
}

proc worker_read {id pipe} {
    if {[catch {gets $pipe line} nbytes]} {
        worker_finish $id $pipe error "Read error: $nbytes"
        return
    }
    if {$nbytes >= 0} {
        # Append line to item's output
        set idx [queue_find_index $id]
        if {$idx >= 0} {
            set item [lindex $::queue $idx]
            set out [dict get $item output]
            append out $line "\n"
            dict set item output $out
            lset ::queue $idx $item
        }
        # Stream to output widget if this item is selected / active
        ui_output_append $line
        return
    }
    # nbytes == -1 → EOF or would-block
    if {[eof $pipe]} {
        # Determine exit status
        catch {close $pipe} err
        if {$err ne ""} {
            worker_finish $id $pipe error ""
        } else {
            worker_finish $id $pipe done ""
        }
    }
    # else: EAGAIN, fileevent will fire again when data arrives
}

proc worker_finish {id pipe status _msg} {
    catch {close $pipe}
    set ::active_pipe ""
    set ::active_id  ""
    queue_update $id status $status
    queue_save
    ui_queue_refresh
    # Kick next item
    after 100 worker_kick
}

# ---------------------------------------------------------------------------
# UI helpers
# ---------------------------------------------------------------------------
proc ui_queue_refresh {} {
    set lb $::W(qlist)
    # Remember selection
    set sel [$lb curselection]
    set sel_idx [expr {$sel ne "" ? [lindex $sel 0] : -1}]

    $lb delete 0 end
    foreach item $::queue {
        set status [dict get $item status]
        set url    [dict get $item url]
        set tag    $status
        set badges {pending { WAIT } downloading { DL.. } done { DONE } error { ERR  }}
        set badge  [expr {[dict exists $badges $status] ? [dict get $badges $status] : { ?    }}]
        $lb insert end "$badge  $url"
        $lb itemconfigure end -foreground [status_color $status]
    }
    # Restore selection
    if {$sel_idx >= 0 && $sel_idx < [$lb size]} {
        $lb selection set $sel_idx
    } elseif {[$lb size] > 0} {
        $lb selection set end
    }
    ui_statusbar_update
}

proc ui_statusbar_update {} {
    set total 0
    set counts {pending 0 downloading 0 done 0 error 0}
    foreach item $::queue {
        set status [dict get $item status]
        incr total
        if {[dict exists $counts $status]} {
            dict set counts $status [expr {[dict get $counts $status] + 1}]
        }
    }
    set pending     [dict get $counts pending]
    set downloading [dict get $counts downloading]
    set done        [dict get $counts done]
    set error       [dict get $counts error]

    set parts [list "Queue: $total"]
    if {$downloading > 0} { lappend parts "$downloading downloading" }
    if {$pending > 0}     { lappend parts "$pending pending" }
    if {$done > 0}        { lappend parts "$done done" }
    if {$error > 0}       { lappend parts "$error error" }

    $::W(statusbar) configure -text [join $parts "  |  "]
}

proc status_color {status} {
    switch $status {
        pending     { return "#aaaaaa" }
        downloading { return "#4fc3f7" }
        done        { return "#81c784" }
        error       { return "#e57373" }
        default     { return "#ffffff" }
    }
}

proc ui_output_clear {} {
    $::W(output) configure -state normal
    $::W(output) delete 1.0 end
    $::W(output) configure -state disabled
}

proc ui_output_append {line} {
    $::W(output) configure -state normal
    $::W(output) insert end "$line\n"
    $::W(output) see end
    $::W(output) configure -state disabled
}

proc ui_output_show {id} {
    ui_output_clear
    set idx [queue_find_index $id]
    if {$idx < 0} return
    set item [lindex $::queue $idx]
    set out [dict get $item output]
    if {$out ne ""} {
        $::W(output) configure -state normal
        $::W(output) insert end $out
        $::W(output) see end
        $::W(output) configure -state disabled
    }
}

proc ui_on_queue_select {args} {
    set sel [$::W(qlist) curselection]
    if {$sel eq ""} return
    set idx [lindex $sel 0]
    set item [lindex $::queue $idx]
    ui_output_show [dict get $item id]
}

proc ui_reset_cmd {} {
    set ::download_cmd $::DEFAULT_DOWNLOAD_CMD
    $::W(cmd_entry) delete 0 end
    $::W(cmd_entry) insert 0 $::download_cmd
}

proc ui_add_url {} {
    set url [string trim [$::W(url_entry) get]]
    if {$url eq ""} return
    queue_add $url
    $::W(url_entry) delete 0 end
}

proc ui_browse_dir {} {
    set chosen [tk_chooseDirectory \
        -title "Choose output directory" \
        -initialdir $::target_dir]
    if {$chosen eq ""} return
    set ::target_dir $chosen
    $::W(dir_entry) delete 0 end
    $::W(dir_entry) insert 0 $chosen
    set cmd [string trim [$::W(cmd_entry) get]]
    if {$cmd ne ""} { set ::download_cmd $cmd }
    config_save
}

proc ui_open_target_dir {} {
    exec xdg-open $::target_dir &
}

proc ui_save_dir {} {
    set dir [string trim [$::W(dir_entry) get]]
    if {$dir ne ""} { set ::target_dir $dir }
    set cmd [string trim [$::W(cmd_entry) get]]
    if {$cmd ne ""} { set ::download_cmd $cmd }
    config_save
}

# ---------------------------------------------------------------------------
# Build the UI
# ---------------------------------------------------------------------------
proc build_ui {} {
    wm title . "ytdl — Download Queue"
    wm minsize . 640 480

    # ---- Top frame: URL input ----
    set top [ttk::frame .top -padding "6 6 6 4"]
    grid $top -row 0 -column 0 -sticky nsew

    ttk::label $top.lurl -text "URL:"
    ttk::entry $top.url  -width 60
    ttk::button $top.add -text "Add" -command ui_add_url

    grid $top.lurl $top.url $top.add -row 0 -padx 4 -pady 2 -sticky w
    grid $top.url -sticky ew
    grid columnconfigure $top 1 -weight 1

    # Bind Enter key in URL entry
    bind $top.url <Return> ui_add_url

    set ::W(url_entry) $top.url

    # ---- Settings frame: command ----
    set cfg [ttk::frame .cfg -padding "6 0 6 4"]
    grid $cfg -row 1 -column 0 -sticky nsew

    ttk::label $cfg.lcmd -text "Command:"
    ttk::entry $cfg.cmd  -width 80
    $cfg.cmd insert 0 $::download_cmd
    ttk::button $cfg.resetcmd -text "Reset" -command ui_reset_cmd

    grid $cfg.lcmd $cfg.cmd $cfg.resetcmd -row 0 -padx 4 -pady 2 -sticky w
    grid $cfg.cmd -sticky ew

    set ::W(cmd_entry) $cfg.cmd

    ttk::label  $cfg.ldir  -text "Directory:"
    ttk::entry  $cfg.dir   -width 40
    $cfg.dir insert 0 $::target_dir
    ttk::button $cfg.browse -text "Browse…" -command ui_browse_dir
    ttk::button $cfg.open    -text "Open"    -command ui_open_target_dir
    ttk::button $cfg.savedir -text "Save"    -command ui_save_dir

    grid $cfg.ldir $cfg.dir $cfg.browse $cfg.open $cfg.savedir -row 1 -padx 4 -pady 2 -sticky w
    grid $cfg.dir -sticky ew
    grid columnconfigure $cfg 1 -weight 1

    set ::W(dir_entry) $cfg.dir

    # ---- Middle: Queue list + controls ----
    set mid [ttk::frame .mid -padding "6 0 6 4"]
    grid $mid -row 2 -column 0 -sticky nsew

    ttk::label $mid.lq -text "Queue:"
    grid $mid.lq -row 0 -column 0 -columnspan 3 -sticky w -padx 4

    listbox $mid.qlist \
        -yscrollcommand "$mid.qscroll set" \
        -selectmode single \
        -font {monospace 10} \
        -background "#1e1e1e" \
        -foreground "#dddddd" \
        -selectbackground "#37474f" \
        -selectforeground "#ffffff" \
        -relief flat \
        -borderwidth 1 \
        -height 12
    ttk::scrollbar $mid.qscroll -orient vertical -command "$mid.qlist yview"

    grid $mid.qlist   -row 1 -column 0 -sticky nsew -padx {4 0}
    grid $mid.qscroll -row 1 -column 1 -sticky ns

    ttk::frame $mid.btns
    ttk::button $mid.btns.remove -text "Remove" -command queue_remove_selected
    ttk::button $mid.btns.clear  -text "Clear done/error" -command queue_clear_done
    pack $mid.btns.remove $mid.btns.clear -side top -fill x -pady 2

    grid $mid.btns -row 1 -column 2 -sticky n -padx 8

    grid columnconfigure $mid 0 -weight 1
    grid rowconfigure    $mid 1 -weight 1

    bind $mid.qlist <<ListboxSelect>> ui_on_queue_select

    set ::W(qlist) $mid.qlist

    # ---- Bottom: Output text ----
    set bot [ttk::frame .bot -padding "6 0 6 6"]
    grid $bot -row 3 -column 0 -sticky nsew

    ttk::label $bot.lout -text "Output:"
    grid $bot.lout -row 0 -column 0 -sticky w -padx 4

    text $bot.output \
        -yscrollcommand "$bot.oscroll set" \
        -font {monospace 9} \
        -background "#0d0d0d" \
        -foreground "#cccccc" \
        -relief flat \
        -borderwidth 1 \
        -state disabled \
        -height 12 \
        -wrap word
    ttk::scrollbar $bot.oscroll -orient vertical -command "$bot.output yview"

    grid $bot.output  -row 1 -column 0 -sticky nsew -padx {4 0}
    grid $bot.oscroll -row 1 -column 1 -sticky ns

    grid columnconfigure $bot 0 -weight 1
    grid rowconfigure    $bot 1 -weight 1

    set ::W(output) $bot.output

    # ---- Status bar ----
    ttk::label .statusbar \
        -text "Queue: 0" \
        -anchor w \
        -padding "8 2 8 2" \
        -relief flat
    ttk::frame .statusright
    ttk::label .statusright.saved \
        -text "" \
        -anchor e \
        -padding "0 2 4 2" \
        -relief flat
    ttk::label .statusright.ver \
        -text "v$::version" \
        -anchor e \
        -padding "0 2 8 2" \
        -relief flat
    pack .statusright.saved .statusright.ver -side left
    grid .statusbar    -row 4 -column 0 -sticky ew
    grid .statusright  -row 4 -column 0 -sticky e

    set ::W(statusbar)   .statusbar
    set ::W(statussaved) .statusright.saved

    # ---- Root window weights ----
    grid columnconfigure . 0 -weight 1
    grid rowconfigure    . 2 -weight 1
    grid rowconfigure    . 3 -weight 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
config_load
queue_load
build_ui
ui_queue_refresh

# Start worker in case there are pending items from a previous session
after 200 worker_kick

# Save queue on window close
wm protocol . WM_DELETE_WINDOW {
    queue_save
    destroy .
}
