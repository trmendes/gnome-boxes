// This file is part of GNOME Boxes. License: LGPLv2
using Config;
using Gtk;
using Gdk;
using GtkClutter;
using Clutter;
using GVir;

private enum Boxes.UIState {
    NONE,
    COLLECTION,
    CREDS,
    DISPLAY,
    SETTINGS,
    WIZARD
}

private errordomain Boxes.Error {
    INVALID
}

private class Boxes.App: Boxes.UI {
    public override Clutter.Actor actor { get { return stage; } }
    public Gtk.Window window;
    public GtkClutter.Embed embed;
    public Clutter.Stage stage;
    public Clutter.State state;
    public Clutter.Box box; // the whole app box
    public CollectionItem current_item; // current object/vm manipulated
    public GVir.Connection connection;
    public static const uint duration = 555;  // default to 1/2 for all transitions

    private Clutter.TableLayout box_table;
    private Collection collection;
    private Sidebar sidebar;
    private Topbar topbar;
    private CollectionView view;

    public App () {
        setup_ui ();
        collection = new Collection ();

        collection.item_added.connect ((item) => {
            item.actor.set_reactive (true);
            item.actor.button_press_event.connect ((actor, event) => {
                return item_clicked (item, event);
            });

            view.add_item (item);
        });

        setup_libvirt.begin ();
    }

    public void set_category (Category category) {
        topbar.label.set_text (category.name);
    }

    private async void setup_libvirt () {
        connection = new GVir.Connection ("qemu:///system");

        try {
            yield connection.open_async (null);
            connection.fetch_domains (null);
        } catch (GLib.Error e) {
            warning (e.message);
        }

        foreach (var domain in connection.get_domains ()) {
            var machine = new Machine (this, domain);
            collection.add_item (machine);
        }
    }

    private void setup_ui () {
        window = new Gtk.Window ();
        window.set_default_size (640, 480);
        embed = new GtkClutter.Embed ();
        embed.show ();
        window.add (embed);
        stage = embed.get_stage () as Clutter.Stage;

        var style = new Gtk.StyleContext ();
        var path = new Gtk.WidgetPath ();
        path.append_type (typeof (Gtk.Window));
        style.set_path (path);
        style.add_class ("boxes-bg");
        var gdk_rgba = style.get_background_color (0);
        Clutter.Color color = {
            (uint8) (gdk_rgba.red * 255).clamp (0, 255),
            (uint8) (gdk_rgba.green * 255).clamp (0, 255),
            (uint8) (gdk_rgba.blue * 255).clamp (0, 255),
            (uint8) (gdk_rgba.alpha * 255).clamp (0, 255)
        };
        stage.set_color (color);

        state = new Clutter.State ();
        state.set_duration (null, null, duration);

        window.destroy.connect (quit);
        window.key_press_event.connect (on_key_pressed);

        box_table = new Clutter.TableLayout ();
        box = new Clutter.Box (box_table);
        box.add_constraint (new Clutter.BindConstraint (stage, BindCoordinate.SIZE, 0));
        stage.add_actor (box);

        topbar = new Topbar (this);
        sidebar = new Sidebar (this);
        view = new CollectionView (this);

        var size_group = new Gtk.SizeGroup (Gtk.SizeGroupMode.HORIZONTAL);
        size_group.add_widget (topbar.corner);
        size_group.add_widget (sidebar.notebook);

        window.show ();

        ui_state = UIState.COLLECTION;
    }

    public void go_back () {
        ui_state = UIState.COLLECTION;
        current_item = null;
    }

    public override void ui_state_changed () {
        message ("Switching layout to %s".printf (ui_state.to_string ()));

        foreach (var o in new Boxes.UI[] { sidebar, topbar, view }) {
            o.ui_state = ui_state;
        }

        switch (ui_state) {
        case UIState.DISPLAY:
            box.set_layout_manager (new Clutter.FixedLayout ());
            state.set_state ("display");
            break;
        case UIState.CREDS:
            box.set_layout_manager (box_table);
            state.set_state ("creds");
            break;
        case UIState.COLLECTION:
            box.set_layout_manager (box_table);
            state.set_state ("collection");

            break;
        default:
            warning ("Unhandled UI state %s".printf (ui_state.to_string ()));
            break;
        }
    }

    public void quit () {
        Gtk.main_quit ();
    }

    private bool on_key_pressed (Widget widget, Gdk.EventKey event) {
        if (event.keyval == F11_KEY) {
            if (WindowState.FULLSCREEN in window.get_window ().get_state ())
                window.unfullscreen ();
            else
                window.fullscreen ();

            return true;
        }

        if (event.keyval == F12_KEY) {
            ui_state = UIState.COLLECTION;
        }

        return false;
    }

    private bool item_clicked (CollectionItem item, Clutter.ButtonEvent event) {
        if (ui_state == UIState.COLLECTION) {
            current_item = item;

            if (current_item is Machine) {
                var machine = current_item as Machine;

                machine.connect_display ();
                ui_state = UIState.CREDS;

            } else
                warning ("unknown item, fix your code");
        }

        return false;
    }
}

private abstract class Boxes.UI: GLib.Object {
    public abstract Clutter.Actor actor { get; }

    private UIState _ui_state;
    [CCode (notify = false)]
    public UIState ui_state {
        get { return _ui_state; }
        set {
            if (_ui_state != value) {
                _ui_state = value;
                ui_state_changed ();
                notify_property ("ui-state");
            }
        }
    }

    public abstract void ui_state_changed ();
}
