// This file is part of GNOME Boxes. License: LGPLv2+

[GtkTemplate (ui = "/org/gnome/Boxes/ui/snapshot-list-row.ui")]
private class Boxes.SnapshotListRow : Gtk.ListBoxRow {
    public GVir.DomainSnapshot snapshot;
    public string activity_message { get; set; default = ""; }

    [GtkChild]
    private Gtk.Revealer delete_revealer;
    [GtkChild]
    private Gtk.Label name_label;
    [GtkChild]
    private Gtk.Stack mode_stack;
    [GtkChild]
    private Gtk.Entry name_entry;
    [GtkChild]
    private Gtk.Box edit_name_box;
    [GtkChild]
    private Gtk.Box show_name_box;

    // index of the snapshot in the list
    private int index;
    private int parent_size;

    private Boxes.LibvirtMachine machine;
    private unowned Gtk.Container? parent_container = null;

    private const GLib.ActionEntry[] action_entries = {
        {"revert-to", revert_to_activated},
        {"rename",    rename_activated},
        {"delete",    delete_activated}
    };

    construct {
        this.get_style_context ().add_class ("boxes-snapshot-list-row");
        this.parent_set.connect (() => {
            var parent = get_parent () as Gtk.Container;

            if (parent == null)
                return;

            this.parent_container = parent;
            update_index ();
            parent.add.connect (update_index);
            parent.remove.connect (update_index);
        });
        this.selectable = false;
        this.activatable = false;
    }


    public SnapshotListRow (GVir.DomainSnapshot snapshot,
                            LibvirtMachine      machine) {
        this.snapshot = snapshot;
        this.machine = machine;

        try {
            name_label.label = snapshot.get_config (0).get_description ();
        } catch (GLib.Error e) {
            critical (e.message);
        }

        var action_group = new GLib.SimpleActionGroup ();
        action_group.add_action_entries (action_entries, this);
        this.insert_action_group ("snap", action_group);

        delete_revealer.notify["child-revealed"].connect (() => {
            if (!delete_revealer.child_revealed) {
                parent_container = (Gtk.Container) this.get_parent ();
                if (parent_container != null)
                    parent_container.remove (this);
            }
        });
    }

    // Need to override this in order to connect the indicators without any gaps.
    public override bool draw (Cairo.Context ct) {
        base.draw (ct);
        var height = this.get_allocated_height ();
        var sc = this.get_style_context ();

        double indicator_size = height / 2.0;

        sc.save ();
        sc.add_class ("indicator");

        var line_color = sc.get_background_color (this.get_state_flags ());
        ct.set_source_rgba (line_color.red, line_color.green, line_color.blue, line_color.alpha);
        ct.set_line_width (4);
        if (index > 0) {
            ct.move_to (height / 2.0 + 0.5, -1);
            ct.line_to (height / 2.0 + 0.5, height / 2.0);
            ct.stroke ();
        }
        if (index < parent_size - 1) {
            ct.move_to (height / 2.0 + 0.5, height / 2.0);
            ct.line_to (height / 2.0 + 0.5, height + 1);
            ct.stroke ();
        }

        bool is_current = false;
        try {
            this.snapshot.get_is_current (0, out is_current);
        } catch (GLib.Error e) {
            warning (e.message);
        }

        if (is_current)
            sc.add_class ("active");

        ct.save();
        sc.render_background (ct, height / 4.0, height / 4.0, indicator_size, indicator_size);
        sc.render_frame (ct, height / 4.0, height / 4.0, indicator_size, indicator_size + 0.5);
        ct.restore();

        sc.restore ();

        return true;
    }

    [GtkCallback]
    private void on_save_name_button_clicked () {
        try {
            var config = snapshot.get_config (0);
            config.set_description (name_entry.text);
            snapshot.set_config (config);
            name_label.label = name_entry.get_text ();
            mode_stack.visible_child = show_name_box;
        } catch (GLib.Error e) {
            warning (e.message);
        }
    }


    private void revert_to_activated (GLib.SimpleAction action, GLib.Variant? v) {
        var snapshot_name = this.snapshot.get_name ();
        var snapshot_state = GVirConfig.DomainSnapshotDomainState.NOSTATE;

        try {
            var snapshot_config = snapshot.get_config (0);
            snapshot_name = snapshot_config.get_description ();
            snapshot_state = snapshot_config.get_state ();
        } catch (GLib.Error e) {}

        var show_activity = (machine.state == Machine.MachineState.RUNNING);
        if (show_activity)
            activity_message = _("Reverting to %s…").printf (snapshot_name);

        if (snapshot_state == GVirConfig.DomainSnapshotDomainState.SHUTOFF) {
            ulong restart_id = 0;
            restart_id = machine.domain.stopped.connect (() => {
                machine.start.begin (Machine.ConnectFlags.NONE, null);
                machine.domain.disconnect (restart_id);
            });
        }

        snapshot.revert_to_async.begin (0, null, (obj, res) => {
            try {
                snapshot.revert_to_async.end (res);
                parent_container.queue_draw ();
            } catch (GLib.Error e) {
                warning (e.message);
                machine.window.notificationbar.display_error (_("Failed to apply snapshot"));
            }
            if (show_activity)
                activity_message = null;
        });
    }


    private void delete_activated (GLib.SimpleAction action, GLib.Variant? v) {
        string snapshot_identifier = snapshot.get_name ();
        try {
            var config = snapshot.get_config (0);
            snapshot_identifier = config.get_description ();
        } catch (GLib.Error e) {
            warning ("Could not get configuration of snapshot %s: %s",
                      snapshot.get_name (),
                      e.message);
        }
        var message = _("Snapshot \"%s\" deleted.").printf (snapshot_identifier);
        delete_revealer.reveal_child = false;

        Notification.OKFunc undo = () => {
            parent_container.add (this);
            this.visible = true;
            delete_revealer.reveal_child = true;
        };

        Notification.CancelFunc really_remove = () => {
            this.snapshot.delete_async.begin (0, null, (obj, res) =>{
                try {
                    this.snapshot.delete_async.end (res);
                    parent_container.queue_draw ();
                } catch (GLib.Error e) {
                    warning ("Error while deleting snapshot %s: %s", snapshot.get_name (), e.message);
                }
            });
        };
        machine.window.notificationbar.display_for_action (message,
                                                           _("_Undo"),
                                                           (owned) undo,
                                                           (owned) really_remove);
    }

    private void rename_activated (GLib.SimpleAction action, GLib.Variant? v) {
        name_entry.text = name_label.get_text ();
        mode_stack.visible_child = edit_name_box;
        name_entry.grab_focus ();
    }

    public void unreveal () {
        delete_revealer.reveal_child = false;
    }

    public void reveal () {
        delete_revealer.reveal_child = true;
    }


    private void update_index () {
        var parent = this.get_parent ();

        if (parent == null || !(parent is Gtk.ListBox))
            return;

        var siblings = (parent as Gtk.Container).get_children ();
        this.index = siblings.index (this);
        this.parent_size = (int) siblings.length ();
    }
}