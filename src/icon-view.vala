// This file is part of GNOME Boxes. License: LGPLv2+

public enum Boxes.SelectionCriteria {
    ALL,
    NONE,
    RUNNING
}

private class Boxes.IconView: Gtk.ScrolledWindow, Boxes.ICollectionView, Boxes.UI {
    public UIState previous_ui_state { get; protected set; }
    public UIState ui_state { get; protected set; }

    public CollectionFilter filter { get; protected set; }

    private Gtk.FlowBox flowbox;

    private GLib.List<CollectionItem> hidden_items;

    private AppWindow window;
    private Boxes.ActionsPopover context_popover;

    private Category _category;
    public Category category {
        get { return _category; }
        set {
            _category = value;
            // FIXME: update view
        }
    }

    construct {
        category = new Category (_("New and Recent"), Category.Kind.NEW);
        hidden_items = new GLib.List<CollectionItem> ();

        setup_flowbox ();

        filter = new CollectionFilter ();
        filter.notify["text"].connect (() => {
            flowbox.invalidate_filter ();
        });
        filter.filter_func_changed.connect (() => {
            flowbox.invalidate_filter ();
        });

        notify["ui-state"].connect (ui_state_changed);
    }

    public void setup_ui (AppWindow window) {
        this.window = window;

        window.notify["selection-mode"].connect (() => {
            flowbox.selection_mode = window.selection_mode ? Gtk.SelectionMode.MULTIPLE :
                                                             Gtk.SelectionMode.NONE;
            update_selection_mode ();
        });

        context_popover = new Boxes.ActionsPopover (window);
    }

    public void add_item (CollectionItem item) {
        var machine = item as Machine;

        if (machine == null) {
            warning ("Cannot add item %p".printf (&item));
            return;
        }

        var window = machine.window;
        if (window.ui_state == UIState.WIZARD) {
            // Don't show newly created items until user is out of wizard
            hidden_items.append (item);

            ulong ui_state_id = 0;

            ui_state_id = window.notify["ui-state"].connect (() => {
                if (window.ui_state == UIState.WIZARD)
                    return;

                if (hidden_items.find (item) != null) {
                    add_item (item);
                    hidden_items.remove (item);
                }
                window.disconnect (ui_state_id);
            });

            return;
        }

        add_child (item);
    }

    private void add_child (CollectionItem item) {
        var child = new Gtk.FlowBoxChild ();
        child.halign = Gtk.Align.START;
        var box = new IconViewChild (item);

        box.notify["selected"].connect (() => {
            propagate_view_child_selection (child);
        });

        box.visible = true;
        child.visible = true;

        child.add (box);
        flowbox.add (child);
    }

    public void remove_item (CollectionItem item) {
        hidden_items.remove (item);
        remove_child (item);
    }

    private void remove_child (CollectionItem item) {
        foreach_child ((box_child) => {
            var view_child = box_child.get_child () as IconViewChild;
            if (view_child == null)
                return;

            if (view_child.item == item) {
                flowbox.remove (view_child);
            }
        });
    }

    public void select_by_criteria (SelectionCriteria criteria) {
        window.selection_mode = true;

        switch (criteria) {
        default:
        case SelectionCriteria.ALL:
            foreach_child ((box_child) => { select_child (box_child); });

            break;
        case SelectionCriteria.NONE:
            foreach_child ((box_child) => { unselect_child (box_child); });

            break;
        case SelectionCriteria.RUNNING:
            foreach_child ((box_child) => {
                var item = get_item_for_child (box_child);
                if (item != null && item is Machine && (item as Machine).is_running)
                    select_child (box_child);
                else
                    unselect_child (box_child);
            });

            break;
        }

        App.app.notify_property ("selected-items");
    }

    public List<CollectionItem> get_selected_items () {
        var selected = new List<CollectionItem> ();

        foreach (var box_child in flowbox.get_selected_children ()) {
            var item = get_item_for_child (box_child);
            selected.append (item);
        }

        return (owned) selected;
    }

    public void activate_first_item () {
        Gtk.FlowBoxChild first_child = null;
        foreach_child ((box_child) => {
            if (first_child == null)
                first_child = box_child;
        });

        if (first_child == null)
            flowbox.child_activated (first_child);
    }

    private void setup_flowbox () {
        flowbox = new Gtk.FlowBox ();

        flowbox.selection_mode = Gtk.SelectionMode.NONE;
        flowbox.valign = Gtk.Align.START;
        flowbox.border_width = 12;
        flowbox.column_spacing = 20;
        flowbox.row_spacing = 6;
        add (flowbox);
        flowbox.show ();

        flowbox.button_release_event.connect (on_button_press_event);
        flowbox.key_press_event.connect (on_key_press_event);

        flowbox.set_filter_func (model_filter);
        flowbox.set_sort_func (model_sort);

        flowbox.child_activated.connect ((child) => {
            if (window.selection_mode)
                return;

            var item = get_item_for_child (child);
            if (item is LibvirtMachine && (item as LibvirtMachine).importing)
                return;

            window.select_item (item);
        });

        update_selection_mode ();
    }

    private CollectionItem? get_item_for_child (Gtk.FlowBoxChild child) {
        var view = child.get_child () as IconViewChild;
        if (view == null)
            return null;

        return view.item;
    }

    private void foreach_child (Func<Gtk.FlowBoxChild> func) {
        flowbox.forall ((child) => {
            var view_child = child as Gtk.FlowBoxChild;
            if (view_child == null)
                return;

            func (view_child);
        });
    }

    private int model_sort (Gtk.FlowBoxChild child1, Gtk.FlowBoxChild child2) {
        var item1 = get_item_for_child (child1);
        var item2 = get_item_for_child (child2);

        if (item1 == null || item2 == null)
            return 0;

        return item1.compare (item2);
    }

    private bool model_filter (Gtk.FlowBoxChild child) {
        if (child  == null)
            return false;

        var item = get_item_for_child (child);
        if (item  == null)
            return false;

        return filter.filter (item as CollectionItem);
    }

    private void ui_state_changed () {
        if (ui_state == UIState.COLLECTION)
            flowbox.unselect_all ();
    }

    private bool on_button_press_event (Gdk.EventButton event) {
        if (event.type != Gdk.EventType.BUTTON_RELEASE || event.button != 3)
            return false;

        var child = flowbox.get_child_at_pos ((int) event.x, (int) event.y);

        return launch_context_popover_for_child (child);
    }

    private bool on_key_press_event (Gdk.EventKey event) {
        if (event.keyval != Gdk.Key.Menu)
            return false;

        var child = flowbox.get_selected_children ().nth_data (0);
        if (child == null)
            return false;

        return launch_context_popover_for_child (child);
    }

    private bool launch_context_popover_for_child (Gtk.FlowBoxChild child) {
        var item = get_item_for_child (child);
        if (item == null)
            return false;

        context_popover.update_for_item (item);
        context_popover.set_relative_to (child);
        context_popover.show ();

        return true;
    }

    private void update_selection_mode () {
        foreach_child ((child) => {
            var view_child = child.get_child () as Boxes.IconViewChild;

            if (view_child.selection_mode != window.selection_mode)
                view_child.selection_mode = window.selection_mode;

            unselect_child (child);
        });
    }

    private void propagate_view_child_selection (Gtk.FlowBoxChild child) {
        var view_child = child.get_child () as IconViewChild;

        if (view_child.selected)
            select_child (child);
        else
            unselect_child (child);
    }

    private void select_child (Gtk.FlowBoxChild child) {
        var view_child = child.get_child () as IconViewChild;

        flowbox.select_child (child);
        if (!view_child.selected)
            view_child.selected = true;

        App.app.notify_property ("selected-items");
    }

    private void unselect_child (Gtk.FlowBoxChild child) {
        var view_child = child.get_child () as IconViewChild;

        flowbox.unselect_child (child);
        if (view_child.selected)
            view_child.selected = false;

        App.app.notify_property ("selected-items");
    }
}
