// This file is part of GNOME Boxes. License: LGPLv2+
using Clutter;

private class Boxes.CollectionView: Boxes.UI {
    public override Clutter.Actor actor { get { return gtkactor; } }

    private GtkClutter.Actor gtkactor;

    private Category _category;
    public Category category {
        get { return _category; }
        set {
            _category = value;
            // FIXME: update view
        }
    }

    private Gtk.IconView icon_view;
    private enum ModelColumns {
        SCREENSHOT,
        TITLE,
        ITEM
    }
    private Gtk.ListStore model;

    public bool visible {
        set { icon_view.visible = value; }
    }

    public CollectionView (Category category) {
        this.category = category;

        setup_view ();
        App.app.notify["selection-mode"].connect (() => {
            var mode = App.app.selection_mode ? Gtk.SelectionMode.MULTIPLE : Gtk.SelectionMode.NONE;
            icon_view.set_selection_mode (mode);
        });
    }

    public override void ui_state_changed () {
        uint opacity = 0;
        switch (ui_state) {
        case UIState.COLLECTION:
            opacity = 255;
            icon_view.unselect_all ();
            if (App.app.current_item != null) {
                var actor = App.app.current_item.actor;
                App.app.overlay_bin.set_alignment (actor,
                                                   Clutter.BinAlignment.FIXED,
                                                   Clutter.BinAlignment.FIXED);
                // TODO: How do I get the icon coords from the iconview?
                actor.x = 20;
                actor.y = 20;
                actor.min_width = actor.natural_width = Machine.SCREENSHOT_WIDTH;
                actor.transitions_completed.connect (() => {
                    if (App.app.ui_state == UIState.COLLECTION ||
                        App.app.current_item.actor != actor)
                        actor_remove (actor);
                });
            }
            break;

        case UIState.CREDS:
            var actor = App.app.current_item.actor;
            if (App.app.current_item.actor.get_parent () == null) {
                App.app.overlay_bin.add (actor,
                                         Clutter.BinAlignment.FIXED,
                                         Clutter.BinAlignment.FIXED);

                // TODO: How do I get the icon coords from the iconview?
                Clutter.ActorBox box = { 20, 20, 20 + Machine.SCREENSHOT_WIDTH, 20 + Machine.SCREENSHOT_HEIGHT * 2};
                actor.allocate (box, 0);
            }
            actor.min_width = actor.natural_width = Machine.SCREENSHOT_WIDTH * 2;
            App.app.overlay_bin.set_alignment (actor,
                                               Clutter.BinAlignment.CENTER,
                                               Clutter.BinAlignment.CENTER);
            break;

        case UIState.PROPERTIES:
            var item_actor = App.app.current_item.actor;
            item_actor.hide ();
            break;
        }

        fade_actor (actor, opacity);

        if (App.app.current_item != null)
            App.app.current_item.ui_state = ui_state;
    }

    public void update_item_visible (CollectionItem item) {
        var visible = false;

        // FIXME
        if (item is Machine) {
            var machine = item as Machine;

            switch (category.kind) {
            case Category.Kind.USER:
                visible = category.name in machine.config.categories;
                break;
            case Category.Kind.NEW:
                visible = true;
                break;
            }
        }

        item.actor.visible = visible;
    }

    private Gtk.TreeIter append (Gdk.Pixbuf pixbuf,
                                 string title,
                                 CollectionItem item)
    {
        Gtk.TreeIter iter;

        model.append (out iter);
        model.set (iter, ModelColumns.SCREENSHOT, pixbuf);
        model.set (iter, ModelColumns.TITLE, title);
        model.set (iter, ModelColumns.ITEM, item);

        item.set_data<Gtk.TreeIter?> ("iter", iter);

        return iter;
    }

    public void add_item (CollectionItem item) {
        var machine = item as Machine;

        if (machine == null) {
            warning ("Cannot add item %p".printf (&item));
            return;
        }

        var iter = append (machine.pixbuf, item.title, item);
        var pixbuf_id = machine.notify["pixbuf"].connect (() => {
            // apparently iter is stable after insertion/removal/sort
            model.set (iter, ModelColumns.SCREENSHOT, machine.pixbuf);
        });
        item.set_data<ulong> ("pixbuf_id", pixbuf_id);

        item.ui_state = UIState.COLLECTION;
        actor_remove (item.actor);

        update_item_visible (item);
    }

    public List<CollectionItem> get_selected_items () {
        var list = new List<CollectionItem> ();
        var selected = icon_view.get_selected_items ();

        foreach (var path in selected)
            list.append (get_item_for_path (path));

        return list;
    }

    public void remove_item (CollectionItem item) {
        var iter = item.get_data<Gtk.TreeIter?> ("iter");
        var pixbuf_id = item.get_data<ulong> ("pixbuf_id");

        if (iter == null) {
            debug ("item not in view or already removed");
            return;
        }

        model.remove (iter);
        item.set_data<Gtk.TreeIter?> ("iter", null);
        item.disconnect (pixbuf_id);
    }

    private CollectionItem get_item_for_path (Gtk.TreePath path) {
        Gtk.TreeIter iter;
        GLib.Value value;

        model.get_iter (out iter, path);
        model.get_value (iter, ModelColumns.ITEM, out value);

        return (CollectionItem) value;
    }

    private void setup_view () {
        model = new Gtk.ListStore (3,
                                   typeof (Gdk.Pixbuf),
                                   typeof (string),
                                   typeof (CollectionItem));
        model.set_default_sort_func ((model, a, b) => {
            CollectionItem item_a, item_b;

            model.get (a, ModelColumns.ITEM, out item_a);
            model.get (b, ModelColumns.ITEM, out item_b);

            if (item_a == null || item_b == null) // FIXME?!
                return 0;

            return item_a.title.collate (item_b.title);
        });
        model.set_sort_column_id (Gtk.SortColumn.DEFAULT, Gtk.SortType.ASCENDING);

        icon_view = new Gtk.IconView.with_model (model);
        icon_view.item_width = 185;
        icon_view.column_spacing = 20;
        icon_view.margin = 16;
        icon_view_activate_on_single_click (icon_view, true);
        icon_view.set_selection_mode (Gtk.SelectionMode.NONE);
        icon_view.item_activated.connect ((view, path) => {
            var item = get_item_for_path (path);
            App.app.select_item (item);
        });
        icon_view.selection_changed.connect (() => {
            App.app.notify_property ("selected-items");
        });
        var pixbuf_renderer = new Gtk.CellRendererPixbuf ();
        pixbuf_renderer.xalign = 0.5f;
        pixbuf_renderer.yalign = 0.5f;
        icon_view.pack_start (pixbuf_renderer, false);
        icon_view.add_attribute (pixbuf_renderer, "pixbuf", ModelColumns.SCREENSHOT);

        var text_renderer = new Gtk.CellRendererText ();
        text_renderer.xalign = 0.5f;
        text_renderer.foreground = "white";
        icon_view.pack_start (text_renderer, false);
        icon_view.add_attribute(text_renderer, "text", ModelColumns.TITLE);

        var scrolled_window = new Gtk.ScrolledWindow (null, null);
        // TODO: this should be set, but doesn't resize correctly the gtkactor..
        //        scrolled_window.hscrollbar_policy = Gtk.PolicyType.NEVER;
        scrolled_window.add (icon_view);
        scrolled_window.show_all ();

        gtkactor = new GtkClutter.Actor.with_contents (scrolled_window);
        gtkactor.name = "collection-view";
    }
}
