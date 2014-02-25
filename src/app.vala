// This file is part of GNOME Boxes. License: LGPLv2+

private abstract class Boxes.Broker : GLib.Object {
    // Overriding subclass should chain-up at the end of its implementation
    public virtual async void add_source (CollectionSource source) {
        var used_configs = new GLib.List<BoxConfig> ();
        foreach (var item in App.app.collection.items.data) {
            if (!(item is Machine))
                continue;

            used_configs.append ((item as Machine).config);
        }

        source.purge_stale_box_configs (used_configs);
    }
}

private class Boxes.App: Gtk.Application, Boxes.UI {
    public static App app;
    public static Boxes.AppWindow window;

    public UIState previous_ui_state { get; protected set; }
    public UIState ui_state { get; protected set; }

    public CollectionItem current_item; // current object/vm manipulated
    public string? uri { get; set; }
    public Collection collection;
    public CollectionFilter filter;

    private bool is_ready;
    public signal void ready ();
    public signal void item_selected (CollectionItem item);

    private HashTable<string,Broker> brokers;
    private HashTable<string,CollectionSource> sources;
    public GVir.Connection default_connection { owned get { return LibvirtBroker.get_default ().get_connection ("QEMU Session"); } }
    public CollectionSource default_source { get { return sources.get ("QEMU Session"); } }

    private GLib.Binding status_bind;
    private ulong got_error_id;

    public App () {
        application_id = "org.gnome.Boxes";
        flags |= ApplicationFlags.HANDLES_COMMAND_LINE;

        app = this;
        sources = new HashTable<string,CollectionSource> (str_hash, str_equal);
        brokers = new HashTable<string,Broker> (str_hash, str_equal);
        filter = new Boxes.CollectionFilter ();
        var action = new GLib.SimpleAction ("quit", null);
        action.activate.connect (() => { quit_app (); });
        add_action (action);

        action = new GLib.SimpleAction ("new", null);
        action.activate.connect (() => { set_state (UIState.WIZARD); });
        add_action (action);

        action = new GLib.SimpleAction ("select-all", null);
        action.activate.connect (() => { window.view.select (SelectionCriteria.ALL); });
        add_action (action);

        action = new GLib.SimpleAction ("select-running", null);
        action.activate.connect (() => { window.view.select (SelectionCriteria.RUNNING); });
        add_action (action);

        action = new GLib.SimpleAction ("select-none", null);
        action.activate.connect (() => { window.view.select (SelectionCriteria.NONE); });
        add_action (action);

        action = new GLib.SimpleAction ("help", null);
        action.activate.connect (() => {
            try {
                Gtk.show_uri (window.get_screen (),
                              "help:gnome-boxes",
                              Gtk.get_current_event_time ());
            } catch (GLib.Error e) {
                warning ("Failed to display help: %s", e.message);
            }
        });
        add_action (action);

        action = new GLib.SimpleAction ("about", null);
        action.activate.connect (() => {
            string[] authors = {
                "Alexander Larsson <alexl@redhat.com>",
                "Christophe Fergeau <cfergeau@redhat.com>",
                "Marc-André Lureau <marcandre.lureau@gmail.com>",
                "Zeeshan Ali (Khattak) <zeeshanak@gnome.org>"
            };
            string[] artists = {
                "Jon McCann <jmccann@redhat.com>",
                "Jakub Steiner <jsteiner@redhat.com>"
            };

            Gtk.show_about_dialog (window,
                                   "artists", artists,
                                   "authors", authors,
                                   "translator-credits", _("translator-credits"),
                                   "comments", _("A simple GNOME 3 application to access remote or virtual systems"),
                                   "copyright", "Copyright 2011 Red Hat, Inc.",
                                   "license-type", Gtk.License.LGPL_2_1,
                                   "logo-icon-name", "gnome-boxes",
                                   "version", Config.VERSION,
                                   "website", "http://live.gnome.org/Boxes",
                                   "wrap-license", true);
        });
        add_action (action);

        notify["ui-state"].connect (ui_state_changed);
    }

    public override void startup () {
        base.startup ();

        string [] args = {};
        unowned string [] args2 = args;
        Gtk.init (ref args2);

        var menu = new GLib.Menu ();
        menu.append (_("New"), "app.new");

        var display_section = new GLib.Menu ();
        menu.append_section (null, display_section);

        menu.append (_("Help"), "app.help");
        menu.append (_("About"), "app.about");
        menu.append (_("Quit"), "app.quit");

        set_app_menu (menu);

        collection = new Collection ();

        collection.item_added.connect ((item) => {
            window.view.add_item (item);
        });
        collection.item_removed.connect ((item) => {
            window.view.remove_item (item);
        });

        brokers.insert ("libvirt", LibvirtBroker.get_default ());
        if (Config.HAVE_OVIRT)
            brokers.insert ("ovirt", OvirtBroker.get_default ());

        setup_sources.begin ((obj, result) => {
            setup_sources.end (result);
            is_ready = true;
            ready ();
        });

        check_cpu_vt_capability.begin ();
        check_module_kvm_loaded.begin ();
    }

    public bool has_broker_for_source_type (string type) {
        return brokers.contains (type);
    }

    public delegate void CallReadyFunc ();
    public void call_when_ready (owned CallReadyFunc func) {
        if (is_ready)
            func ();
        ready.connect (() => {
            func ();
        });
    }

    public override void activate () {
        base.activate ();

        if (window != null)
            return;

        window = new Boxes.AppWindow (this);
        window.setup_ui ();
        set_state (UIState.COLLECTION);

        window.present ();
    }

    static bool opt_fullscreen;
    static bool opt_help;
    static string opt_open_uuid;
    static string[] opt_uris;
    static string[] opt_search;
    static const OptionEntry[] options = {
        { "version", 0, 0, OptionArg.NONE, null, N_("Display version number"), null },
        { "help", 'h', OptionFlags.HIDDEN, OptionArg.NONE, ref opt_help, null, null },
        { "full-screen", 'f', 0, OptionArg.NONE, ref opt_fullscreen, N_("Open in full screen"), null },
        { "checks", 0, 0, OptionArg.NONE, null, N_("Check virtualization capabilities"), null },
        { "open-uuid", 0, 0, OptionArg.STRING, ref opt_open_uuid, N_("Open box with UUID"), null },
        { "search", 0, 0, OptionArg.STRING_ARRAY, ref opt_search, N_("Search term"), null },
        // A 'broker' is a virtual-machine manager (could be local or remote). Currently libvirt is the only one supported.
        { "", 0, 0, OptionArg.STRING_ARRAY, ref opt_uris, N_("URI to display, broker or installer media"), null },
        { null }
    };

    public override int command_line (GLib.ApplicationCommandLine cmdline) {
        opt_fullscreen = false;
        opt_help = false;
        opt_open_uuid = null;
        opt_uris = null;
        opt_search = null;

        var parameter_string = _("- A simple application to access remote or virtual machines");
        var opt_context = new OptionContext (parameter_string);
        opt_context.add_main_entries (options, null);
        opt_context.set_help_enabled (false);

        try {
            string[] args1 = cmdline.get_arguments();
            unowned string[] args2 = args1;
            opt_context.parse (ref args2);
        } catch (OptionError error) {
            cmdline.printerr ("%s\n", error.message);
            cmdline.printerr (opt_context.get_help (true, null));
            return 1;
        }

        if (opt_help) {
            cmdline.printerr (opt_context.get_help (true, null));
            return 1;
        }

        if (opt_uris.length > 1 ||
            (opt_open_uuid != null && opt_uris != null)) {
            cmdline.printerr (_("Too many command line arguments specified.\n"));
            cmdline.printerr (opt_context.get_help (true, null));
            return 1;
        }

        activate ();

        var app = this;
        if (opt_open_uuid != null) {
            var uuid = opt_open_uuid;
            call_when_ready (() => {
                    app.open_uuid (uuid);
            });
        } else if (opt_uris != null) {
            var arg = opt_uris[0];

            call_when_ready (() => {
                var file = File.new_for_commandline_arg (arg);
                var is_uri = (Uri.parse_scheme (arg) != null);

                if (file.query_exists ()) {
                    if (is_uri)
                        window.wizard.open_with_uri (file.get_uri ());
                    else
                        window.wizard.open_with_uri (arg);
                } else if (is_uri)
                    window.wizard.open_with_uri (file.get_uri ());
                else
                    open_name (arg);
            });
        }

        if (opt_search != null) {
            call_when_ready (() => {
                window.searchbar.text = string.joinv (" ", opt_search);
                if (ui_state == UIState.COLLECTION)
                    window.searchbar.search_mode_enabled = true;
            });
        }

        if (opt_fullscreen)
            window.fullscreened = true;

        return 0;
    }

    public bool quit_app () {
        window.hide ();

        Idle.add (() => {
            quit ();

            return false;
        });

        return true;
    }

    public override void shutdown () {
        base.shutdown ();

        window.notificationbar.cancel ();
        window.wizard.cleanup ();
        suspend_machines ();
    }

    public void open_name (string name) {
        set_state (UIState.COLLECTION);
        // we don't want to show the collection items as it will
        // appear as a glitch when opening a box immediately
        window.view.visible = false;

        // after "ready" all items should be listed
        foreach (var item in collection.items.data) {
            if (item.name == name) {
                select_item (item);

                break;
            }
        }
    }

    public bool open_uuid (string uuid) {
        set_state (UIState.COLLECTION);
        // we don't want to show the collection items as it will
        // appear as a glitch when opening a box immediately
        window.view.visible = false;

        // after "ready" all items should be listed
        foreach (var item in collection.items.data) {
            if (!(item is Boxes.Machine))
                continue;
            var machine = item as Boxes.Machine;

            if (machine.config.uuid != uuid)
                continue;

            select_item (item);
            return true;
        }

        return false;
    }

    public void delete_machine (Machine machine, bool by_user = true) {
        machine.delete (by_user);         // Will also delete associated storage volume if by_user is 'true'
        collection.remove_item (machine);
    }

    public async void add_collection_source (CollectionSource source) {
        if (!source.enabled)
            return;

        if (sources.get (source.name) != null) {
            warning ("Attempt to add duplicate collection source '%s', ignoring..", source.name);
            return; // Already added
        }

        switch (source.source_type) {
        case "vnc":
        case "spice":
            try {
                var machine = new RemoteMachine (source);
                collection.add_item (machine);
            } catch (Boxes.Error error) {
                warning (error.message);
            }
            break;

        default:
            Broker? broker = brokers.lookup (source.source_type);
            if (broker != null) {
                yield broker.add_source (source);
                sources.insert (source.name, source);
                if (source.name == "QEMU Session") {
                    notify_property ("default-connection");
                    notify_property ("default-source");
                }
            } else {
                warning ("Unsupported source type %s", source.source_type);
            }
            break;
        }
    }

    private async void setup_sources () {

        if (!FileUtils.test (get_user_pkgconfig_source ("QEMU Session"), FileTest.IS_REGULAR)) {
            var src = File.new_for_path (get_pkgdata_source ("QEMU_Session"));
            var dst = File.new_for_path (get_user_pkgconfig_source ("QEMU Session"));
            try {
                yield src.copy_async (dst, FileCopyFlags.NONE);
            } catch (GLib.Error error) {
                critical ("Can't setup default sources: %s", error.message);
            }
        }

        var dir = File.new_for_path (get_user_pkgconfig_source ());
        var new_sources = new GLib.List<CollectionSource> ();
        yield foreach_filename_from_dir (dir, (filename) => {
            var source = new CollectionSource.with_file (filename);
            new_sources.append (source);
            return false;
        });

        foreach (var source in new_sources)
            yield add_collection_source (source);

        if (default_connection == null) {
            printerr ("Missing or failing default libvirt connection\n");
            release (); // will end application
        }
    }

    private void ui_state_changed () {
        window.set_state (ui_state);

        if (ui_state == UIState.COLLECTION) {
            status_bind = null;
            window.topbar.status = null;
            if (current_item is Machine) {
                var machine = current_item as Machine;
                if (got_error_id != 0) {
                    machine.disconnect (got_error_id);
                    got_error_id = 0;
                }

                machine.connecting_cancellable.cancel (); // Cancel any in-progress connections
            }
        }

        if (current_item != null)
            current_item.set_state (ui_state);
    }

    private void suspend_machines () {
        // if we are not the main Boxes instance, 'collection' won't
        // be set as it's created in GtkApplication::startup()
        if (collection == null)
            return;

        debug ("Suspending running boxes");

        var waiting_counter = 0;
        // use a private main context to suspend the VMs to avoid
        // DBus or other callbacks being fired while we suspend
        // the VMs during Boxes shutdown.
        var context = new MainContext ();

        context.push_thread_default ();
        foreach (var item in collection.items.data) {
            if (item is LibvirtMachine) {
                var machine = item as LibvirtMachine;

                if (machine.suspend_at_exit) {
                    waiting_counter++;
                    machine.suspend.begin (() => {
                        debug ("%s suspended", machine.name);
                        waiting_counter--;
                    });
                }
            }
        }
        context.pop_thread_default ();

        // wait for async methods to complete
        while (waiting_counter > 0)
            context.iteration (true);

        debug ("Running boxes suspended");
    }

    private bool _selection_mode;
    public bool selection_mode { get { return _selection_mode; }
        set {
            return_if_fail (ui_state == UIState.COLLECTION);

            _selection_mode = value;
        }
    }

    public List<CollectionItem> selected_items {
        owned get { return window.view.get_selected_items (); }
    }

    public void show_properties () {
        var selected_items = window.view.get_selected_items ();

        selection_mode = false;

        // Show for the first selected item
        foreach (var item in selected_items) {
            current_item = item;
            set_state (UIState.PROPERTIES);
            break;
        }
    }

    public void remove_selected_items () {
        var selected_items = window.view.get_selected_items ();
        var num_selected = selected_items.length ();
        if (num_selected == 0)
            return;

        selection_mode = false;

        var message = (num_selected == 1) ? _("Box '%s' has been deleted").printf (selected_items.data.name) :
                                            ngettext ("%u box has been deleted",
                                                      "%u boxes have been deleted",
                                                      num_selected).printf (num_selected);
        foreach (var item in selected_items)
            collection.remove_item (item);

        Notification.OKFunc undo = () => {
            debug ("Box deletion cancelled by user, re-adding to view");
            foreach (var selected in selected_items) {
                collection.add_item (selected);
            }
        };

        Notification.CancelFunc really_remove = () => {
            debug ("Box deletion, deleting now");
            foreach (var selected in selected_items) {
                var machine = selected as Machine;

                if (machine != null)
                    machine.delete ();
            }
        };

        window.notificationbar.display_for_action (message, _("_Undo"), (owned) undo, (owned) really_remove);
    }

    public void connect_to (Machine machine) {
        current_item = machine;

        // Track machine status in toobar
        status_bind = machine.bind_property ("status", window.topbar, "status", BindingFlags.SYNC_CREATE);

        got_error_id = machine.got_error.connect ( (message) => {
            window.notificationbar.display_error (message);
        });

        if (ui_state != UIState.CREDS)
            set_state (UIState.CREDS); // Start the CREDS state
    }

    public void select_item (CollectionItem item) {
        if (ui_state == UIState.COLLECTION && !selection_mode) {
            current_item = item;

            if (current_item is Machine) {
                var machine = current_item as Machine;

                connect_to (machine);
            } else
                warning ("unknown item, fix your code");

            item_selected (item);
        } else if (ui_state == UIState.WIZARD) {
            current_item = item;

            set_state (UIState.PROPERTIES);
        }
    }
}
