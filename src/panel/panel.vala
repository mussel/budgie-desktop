/*
 * This file is part of budgie-desktop
 * 
 * Copyright (C) 2015-2016 Ikey Doherty <ikey@solus-project.com>
 * 
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

using LibUUID;

namespace Budgie
{


public static const string WM_DBUS_NAME        = "com.solus_project.budgie.BudgieWM";
public static const string WM_DBUS_OBJECT_PATH = "/com/solus_project/budgie/BudgieWM";

[DBus (name="com.solus_project.budgie.BudgieWM")]
public interface BudgieWMDBUS : Object
{
    public abstract void store_focused() throws Error;
    public abstract void restore_focused() throws Error;
}

/**
 * The main panel area - i.e. the bit that's rendered
 */
public class MainPanel : Gtk.Box
{
    public int intended_size { public get ; public set ; }

    public MainPanel(int size)
    {
        Object(orientation: Gtk.Orientation.HORIZONTAL);
        this.intended_size = size;
        get_style_context().add_class("budgie-panel");
        get_style_context().add_class(Gtk.STYLE_CLASS_BACKGROUND);
    }

    public override void get_preferred_height(out int m, out int n)
    {
        m = intended_size - 5;
        n = intended_size - 5;
    }
    public override void get_preferred_height_for_width(int w, out int m, out int n)
    {
        m = intended_size - 5;
        n = intended_size - 5;
    }
}

/**
 * The toplevel window for a panel
 */
public class Panel : Budgie.Toplevel
{

    Gdk.Rectangle scr;
    Gdk.Rectangle small_scr;
    Gdk.Rectangle orig_scr;

    Gtk.Box layout;
    Gtk.Box main_layout;

    public Settings settings { construct set ; public get; }
    private unowned Budgie.PanelManager? manager;

    PopoverManager? popover_manager;
    bool expanded = true;
    BudgieWMDBUS? wm_proxy = null;

    Budgie.ShadowBlock shadow;

    HashTable<string,HashTable<string,string>> pending = null;
    HashTable<string,HashTable<string,string>> creating = null;
    HashTable<string,Budgie.AppletInfo?> applets = null;

    HashTable<string,Budgie.AppletInfo?> initial_config = null;

    List<string?> expected_uuids;

    construct {
        position = PanelPosition.NONE;
    }

    /* Multiplier for strut operations on hi-dpi */
    int scale = 1;

    /* Box for the start of the panel */
    Gtk.Box? start_box;
    /* Box for the center of the panel */
    Gtk.Box? center_box;
    /* Box for the end of the panel */
    Gtk.Box? end_box;

    int[] icon_sizes = {
        16, 24, 32, 48, 96, 128, 256
    };

    int current_icon_size;
    int current_small_icon_size;

    /* Track initial load */
    private bool is_fully_loaded = false;
    private bool need_migratory = false;

    public signal void panel_loaded();

    /* Animation tracking */
    private double render_scale = 0.0;
    private bool initial_anim = false;
    public double nscale {
        public set {
            render_scale = value;
            queue_draw();
        }
        public get {
            return render_scale;
        }
    }

    /* Hold onto our WM proxy ref */
    void on_wm_get(GLib.Object? o, GLib.AsyncResult? res)
    {
        try {
            wm_proxy = Bus.get_proxy.end(res);
        } catch (Error e) {
            warning("Failed to gain WM proxy: %s", e.message);
        }
    }

    /**
     * Asynchronously fetch a BudgieWMDBUS proxy
     */
    void get_wm()
    {
        /* Hook up proxy handler.. */
        Bus.watch_name(BusType.SESSION, WM_DBUS_NAME, BusNameWatcherFlags.NONE,
            has_wm_proxy, lost_wm_proxy);
    }

    void lost_wm_proxy()
    {
        wm_proxy = null;
    }

    void has_wm_proxy()
    {
        if (wm_proxy == null) {
            Bus.get_proxy.begin<BudgieWMDBUS>(BusType.SESSION, WM_DBUS_NAME, WM_DBUS_OBJECT_PATH, 0, null, on_wm_get);
        }
    }

    public bool activate_action(int remote_action)
    {
        unowned string? uuid = null;
        unowned Budgie.AppletInfo? info = null;

        Budgie.PanelAction action = (Budgie.PanelAction)remote_action;

        var iter = HashTableIter<string?,Budgie.AppletInfo?>(applets);
        while (iter.next(out uuid, out info)) {
            if ((info.applet.supported_actions & action) != 0) {
                this.present();

                Idle.add(()=> {
                    info.applet.invoke_action(action);
                    return false;
                });
                return true;
            }
        }
        return false;
    }

    /**
     * Force update the geometry
     */
    public void update_geometry(Gdk.Rectangle screen, PanelPosition position, int size = 0)
    {
        Gdk.Rectangle small = screen;
        string old_class = Budgie.position_class_name(this.position);
        if (old_class != "") {
            this.get_style_context().remove_class(old_class);
        }

        if (size == 0) {
            size = intended_size;
        }

        this.settings.set_int(Budgie.PANEL_KEY_SIZE, size);

        this.intended_size = size;

        this.get_style_context().add_class(Budgie.position_class_name(position));

        switch (position) {
            case PanelPosition.TOP:
            case PanelPosition.BOTTOM:
                small.height = intended_size;
                break;
            default:
                small.width = intended_size;
                break;
        }
        if (position != this.position) {
            this.settings.set_enum(Budgie.PANEL_KEY_POSITION, position);
        }
        this.position = position;
        this.small_scr = small;
        this.orig_scr = screen;

        if (this.expanded) {
            this.scr = this.orig_scr;
        } else {
            this.scr = this.small_scr;
        }
        shadow.required_size = orig_scr.width;
        this.shadow.position = position;
        this.layout.queue_resize();
        queue_resize();
        placement();
        update_sizes();
    }

    public override void reset_shadow()
    {
        this.shadow.required_size = this.orig_scr.width;
        this.shadow.removal = 0;
    }

    public override GLib.List<AppletInfo?> get_applets()
    {
        GLib.List<Budgie.AppletInfo?> ret = new GLib.List<Budgie.AppletInfo?>();
        unowned string? key = null;
        unowned Budgie.AppletInfo? appl_info = null;

        var iter = HashTableIter<string,Budgie.AppletInfo?>(applets);
        while (iter.next(out key, out appl_info)) {
            ret.append(appl_info);
        }
        return ret;
    }

    /**
     * Loop the applets, performing a reparent or reposition
     */
    private void initial_applet_placement(bool repar = false, bool repos = false)
    {
        if (!repar && !repos) {
            return;
        }
        unowned string? uuid = null;
        unowned Budgie.AppletInfo? info = null;

        var iter = HashTableIter<string?,Budgie.AppletInfo?>(applets);

        while (iter.next(out uuid, out info)) {
            if (repar) {
                applet_reparent(info);
            }
            if (repos) {
                applet_reposition(info);
            }
        }
    }

    /* Handle being "fully" loaded */
    private void on_fully_loaded()
    {
        if (applets.size() < 1) {
            if (!initial_anim) {
                Idle.add(initial_animation);
            }
            return;
        }

        /* All applets loaded and positioned, now re-sort them */
        initial_applet_placement(true, false);
        initial_applet_placement(false, true);

        /* Let everyone else know we're in business */
        applets_changed();
        if (!initial_anim) {
            Idle.add(initial_animation);
        }
        lock (need_migratory) {
            if (!need_migratory) {
                return;
            }
        }
        /* In half a second, add_migratory so the user sees them added */
        Timeout.add(500, add_migratory);
    }

    private bool initial_animation()
    {
        this.initial_anim = true;

        var anim = new Budgie.Animation();
        anim.widget = this;
        anim.length = 512 * Budgie.MSECOND;
        anim.tween = Budgie.sine_ease_out;
        anim.changes = new Budgie.PropChange[] {
            Budgie.PropChange() {
                property = "nscale",
                old = 1.0,
                @new = 0.0
            }
        };

        anim.start((a)=> {
            if ((a.widget as Budgie.Panel).nscale == 1.0) {
                a.widget.hide();
            } else {
                (a.widget as Gtk.Window).show();
            }
        });
        return false;
    }

    public Panel(Budgie.PanelManager? manager, string? uuid, Settings? settings)
    {
        Object(type_hint: Gdk.WindowTypeHint.DOCK, window_position: Gtk.WindowPosition.NONE, settings: settings, uuid: uuid);

        initial_config = new HashTable<string,Budgie.AppletInfo>(str_hash, str_equal);

        intended_size = settings.get_int(Budgie.PANEL_KEY_SIZE);
        this.manager = manager;

        skip_taskbar_hint = true;
        skip_pager_hint = true;
        set_decorated(false);
    
        scale = get_scale_factor();
        nscale = 1.0;

        // Respond to a scale factor change
        notify["scale-factor"].connect(()=> {
            this.scale = get_scale_factor();
            this.placement();
        });

        popover_manager = new PopoverManagerImpl(this);
        pending = new HashTable<string,HashTable<string,string>>(str_hash, str_equal);
        creating = new HashTable<string,HashTable<string,string>>(str_hash, str_equal);
        applets = new HashTable<string,Budgie.AppletInfo?>(str_hash, str_equal);
        expected_uuids = new List<string?>();
        panel_loaded.connect(on_fully_loaded);

        var vis = screen.get_rgba_visual();
        if (vis == null) {
            warning("Compositing not available, things will Look Bad (TM)");
        } else {
            set_visual(vis);
        }
        resizable = false;
        app_paintable = true;
        get_style_context().add_class("budgie-container");

        main_layout = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        add(main_layout);


        layout = new MainPanel(intended_size);
        layout.vexpand = false;
        vexpand = false;
        main_layout.pack_start(layout, false, false, 0);
        main_layout.valign = Gtk.Align.START;

        /* Shadow.. */
        shadow = new Budgie.ShadowBlock(this.position);
        shadow.no_show_all = true;
        shadow.hexpand = false;
        shadow.halign = Gtk.Align.START;
        shadow.show_all();
        main_layout.pack_start(shadow, false, false, 0);

        this.settings.bind(Budgie.PANEL_KEY_SHADOW, shadow, "visible", SettingsBindFlags.GET);

        shadow_visible = this.settings.get_boolean(Budgie.PANEL_KEY_SHADOW);
        this.settings.bind(Budgie.PANEL_KEY_SHADOW, this, "shadow-visible", SettingsBindFlags.DEFAULT);

        this.bind_property("shadow-width", shadow, "removal");
        this.bind_property("intended-size", layout, "intended-size");

        /* Assign our applet holder boxes */
        start_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 2);
        start_box.halign = Gtk.Align.START;
        layout.pack_start(start_box, true, true, 0);
        center_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 2);
        layout.set_center_widget(center_box);
        end_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 2);
        layout.pack_end(end_box, true, true, 0);
        end_box.halign = Gtk.Align.END;

        this.theme_regions = this.settings.get_boolean(Budgie.PANEL_KEY_REGIONS);
        this.notify["theme-regions"].connect(update_theme_regions);
        this.settings.bind(Budgie.PANEL_KEY_REGIONS, this, "theme-regions", SettingsBindFlags.DEFAULT);
        this.update_theme_regions();

        get_child().show_all();
        set_expanded(false);

        this.manager.extension_loaded.connect_after(this.on_extension_loaded);

        this.get_wm();

        /* bit of a no-op. */
        update_sizes();
        load_applets();
    }

    void update_theme_regions()
    {
        if (this.theme_regions) {
            start_box.get_style_context().add_class("start-region");
            center_box.get_style_context().add_class("center-region");
            end_box.get_style_context().add_class("end-region");
        } else {
            start_box.get_style_context().remove_class("start-region");
            center_box.get_style_context().remove_class("center-region");
            end_box.get_style_context().remove_class("end-region");
        }
        this.queue_draw();
    }

    void update_sizes()
    {
        int size = icon_sizes[0];
        int small_size = icon_sizes[0];

        unowned string? key = null;
        unowned Budgie.AppletInfo? info = null;

        for (int i = 1; i < icon_sizes.length; i++) {
            if (icon_sizes[i] > intended_size - 5) {
                break;
            }
            size = icon_sizes[i];
            small_size = icon_sizes[i-1];
        }

        this.current_icon_size = size;
        this.current_small_icon_size = small_size;

        var iter = HashTableIter<string?,Budgie.AppletInfo?>(applets);
        while (iter.next(out key, out info)) {
            info.applet.panel_size_changed(intended_size - 5, size, small_size);
        }
    }

    public void destroy_children()
    {
        unowned string key;
        unowned AppletInfo? info;

        var iter = HashTableIter<string?,AppletInfo?>(applets);
        while (iter.next(out key, out info)) {
            Settings? app_settings = info.applet.get_applet_settings(info.uuid);

            // Stop it screaming when it dies
            ulong notify_id = info.get_data("notify_id");

            SignalHandler.disconnect(info, notify_id);
            info.applet.get_parent().remove(info.applet);

            // Nuke our settings for it 8
            info.settings.reset(null);

            // Nuke it's own settings
            if (app_settings != null) {
                app_settings.reset(null);
            }
        }
    }

    void on_extension_loaded(string name)
    {
        unowned HashTable<string,string>? todo = null;
        todo = pending.lookup(name);
        if (todo != null) {
            var iter = HashTableIter<string,string>(todo);
            string? uuid = null;

            while (iter.next(out uuid, null)) {
                string? uname = null;
                Budgie.AppletInfo? info = this.manager.load_applet_instance(uuid, out uname);
                if (info == null) {
                    critical("Failed to load applet when we know it exists: %s", uname);
                    return;
                }
                this.add_applet(info);
            }
            pending.remove(name);
        }

        todo = null;

        todo = creating.lookup(name);
        if (todo != null) {
            var iter = HashTableIter<string,string>(todo);
            string? uuid = null;

            while (iter.next(out uuid, null)) {
                Budgie.AppletInfo? info = this.manager.create_new_applet(name, uuid);
                if (info == null) {
                    critical("Failed to load applet when we know it exists");
                    return;
                }
                this.add_applet(info);
                /* this.configure_applet(info); */
            }
            creating.remove(name);
        }
    }

    /**
     * Load all pre-configured applets
     */
    void load_applets()
    {
        string[]? applets = settings.get_strv(Budgie.PANEL_KEY_APPLETS);
        if (applets == null || applets.length == 0) {
            this.panel_loaded();
            this.is_fully_loaded = true;
            return;
        }

        /* Two loops so we can track when we've fully loaded the panel */
        lock (expected_uuids) {
            for (int i = 0; i < applets.length; i++) {
                this.expected_uuids.append(applets[i]);
            }

            for (int i = 0; i < applets.length; i++) {
                string? name = null;
                Budgie.AppletInfo? info = this.manager.load_applet_instance(applets[i], out name);

                if (info == null) {
                    /* Faiiiil */
                    if (name == null) {
                        unowned List<string?> g = expected_uuids.find_custom(applets[i], GLib.strcmp);
                        /* TODO: No longer expecting this guy to load */
                        if (g != null) {
                            expected_uuids.remove_link(g);
                        }
                        message("Unable to load invalid applet: %s", applets[i]);
                        continue;
                    }
                    this.add_pending(applets[i], name);
                    manager.modprobe(name);
                } else {
                    /* um add this bro to the panel :o */
                    this.add_applet(info);
                }
            }
        }
    }

    /**
     * Add a new applet to the panel (Raven UI)
     *
     * Explanation: Try to find the most underpopulated region first,
     * and add the applet there. Determine a suitable position,
     * set the alignment+position, stuff an initial config in,
     * and hope for the best when we initiate add_new
     *
     * If the @target_region is set, we'll use that instead
     */
    private void add_new_applet_at(string id, Gtk.Box? target_region)
    {
        /* First, determine a panel to place this guy */
        int position = (int) applets.size() + 1;
        unowned Gtk.Box? target = null;
        string? align = null;
        AppletInfo? info = null;
        string? uuid = null;

        Gtk.Box?[] regions = {
            start_box,
            center_box,
            end_box
        };

        /* Use the requested target_region for internal migration adds */
        if (target_region != null) {
            var kids = target_region.get_children();
            position = (int) (kids.length());
            target = target_region;
        } else {
            /* No region specified, find the first available slot */
            foreach (var region in regions) {
                var kids = region.get_children();
                var len = kids.length();
                if (len < position) {
                    position = (int)len;
                    target = region;
                }
            }
        }

        if (target == start_box) {
            align = "start";
        } else if (target == center_box) {
            align = "center";
        } else {
            align = "end";
        }

        uuid = LibUUID.new(UUIDFlags.LOWER_CASE|UUIDFlags.TIME_SAFE_TYPE);
        info = new AppletInfo(null, uuid, null, null);
        info.alignment = align;

        /* Safety clamp */
        var kids = target.get_children();
        uint nkids = kids.length();
        if (position >= nkids) {
            position = (int) nkids;
        }
        if (position < 0) {
            position = 0;
        }

        info.position = position;

        initial_config.insert(uuid, info);
        add_new(id, uuid);
    }

    /**
     * Add a new applet to the panel (Raven UI)
     */
    public override void add_new_applet(string id)
    {
        add_new_applet_at(id, null);
    }

    public void create_default_layout(string name, KeyFile config)
    {
        int s_index = -1;
        int c_index = -1;
        int e_index = -1;
        int index = 0;

        try {
            if (!config.has_key(name, "Children")) {
                warning("Config for panel %s does not specify applets", name);
                return;
            }
            string[] applets = config.get_string_list(name, "Children");
            foreach (string appl in applets) {
                AppletInfo? info = null;
                string? uuid = null;
                appl = appl.strip();
                string alignment = "start"; /* center, end */

                if (!config.has_group(appl)) {
                    warning("Panel applet %s missing from config", appl);
                    continue;
                }

                if (!config.has_key(appl, "ID")) {
                    warning("Applet %s is missing ID", appl);
                    continue;
                }

                uuid = LibUUID.new(UUIDFlags.LOWER_CASE|UUIDFlags.TIME_SAFE_TYPE);

                var id = config.get_string(appl, "ID").strip();
                if (uuid == null || uuid.strip() == "") {
                    warning("Could not add new applet %s from config %s", id, name);
                    continue;
                }

                info = new AppletInfo(null, uuid, null, null);
                if (config.has_key(appl, "Alignment")) {
                    alignment = config.get_string(appl, "Alignment").strip();
                }

                switch (alignment) {
                    case "center":
                        index = ++c_index;
                        break;
                    case "end":
                        index = ++e_index;
                        break;
                    default:
                        index = ++s_index;
                        break;
                }
                info.alignment = alignment;
                info.position = index;

                initial_config.insert(uuid, info);
                add_new(id, uuid);
            }
        } catch (Error e) {
            warning("Error loading default config: %s", e.message);
        }
    }

    void set_applets()
    {
        string[]? uuids = null;
        unowned string? uuid = null;
        unowned Budgie.AppletInfo? plugin = null;

        var iter = HashTableIter<string,Budgie.AppletInfo?>(applets);
        while (iter.next(out uuid, out plugin)) {
            uuids += uuid;
        }

        settings.set_strv(Budgie.PANEL_KEY_APPLETS, uuids);
    }

    public override void remove_applet(Budgie.AppletInfo? info)
    {
        int position = info.position;
        string alignment = info.alignment;
        string uuid = info.uuid;

        ulong notify_id = info.get_data("notify_id");

        SignalHandler.disconnect(info, notify_id);
        info.applet.get_parent().remove(info.applet);

        Settings? app_settings = info.applet.get_applet_settings(uuid);

        info.settings.reset(null);

        /* TODO: Add refcounting and unload unused plugins. */
        applets.remove(uuid);
        applet_removed(uuid);

        if (app_settings != null) {
            app_settings.reset(null);
        }

        set_applets();
        budge_em_left(alignment, position);
    }

    void add_applet(Budgie.AppletInfo? info)
    {
        unowned Gtk.Box? pack_target = null;
        Budgie.AppletInfo? initial_info = null;

        initial_info = initial_config.lookup(info.uuid);
        if (initial_info != null) {
            info.alignment = initial_info.alignment;
            info.position = initial_info.position;
            initial_config.remove(info.uuid);
        }

        if (!this.is_fully_loaded) {
            lock (expected_uuids) {
                unowned List<string?> exp_fin = expected_uuids.find_custom(info.uuid, GLib.strcmp);
                if (exp_fin != null) {
                    expected_uuids.remove_link(exp_fin);
                }
            }
        }

        /* figure out the alignment */
        switch (info.alignment) {
            case "start":
                pack_target = start_box;
                break;
            case "end":
                pack_target = end_box;
                break;
            default:
                pack_target = center_box;
                break;
        }

        this.applets.insert(info.uuid, info);
        this.set_applets();

        info.applet.update_popovers(this.popover_manager);
        info.applet.panel_size_changed(intended_size, this.current_icon_size, this.current_small_icon_size);
        pack_target.pack_start(info.applet, false, false, 0);

        pack_target.child_set(info.applet, "position", info.position);
        ulong id = info.notify.connect(applet_updated);
        info.set_data("notify_id", id);
        this.applet_added(info);

        if (this.is_fully_loaded) {
            return;
        }

        lock (expected_uuids) {
            if (expected_uuids.length() == 0) {
                this.is_fully_loaded = true;
                this.panel_loaded();
            }
        }
    }

    void applet_reparent(Budgie.AppletInfo? info)
    {
        /* Handle being reparented. */
        unowned Gtk.Box? new_parent = null;
        switch (info.alignment) {
            case "start":
                new_parent = this.start_box;
                break;
            case "end":
                new_parent = this.end_box;
                break;
            default:
                new_parent = this.center_box;
                break;
        }
        /* Don't needlessly reparent */
        if (new_parent == info.applet.get_parent()) {
            return;
        }
        info.applet.reparent(new_parent);
    }

    void applet_reposition(Budgie.AppletInfo? info)
    {
        info.applet.get_parent().child_set(info.applet, "position", info.position);
    }

    void applet_updated(Object o, ParamSpec p)
    {
        unowned AppletInfo? info = o as AppletInfo;

        /* Prevent a massive amount of resorting */
        if (!this.is_fully_loaded) {
            return;
        }

        if (p.name == "alignment") {
            applet_reparent(info);
        } else if (p.name == "position") {
            applet_reposition(info);
        }
        this.applets_changed();
    }

    void add_new(string plugin_name, string? initial_uuid = null)
    {
        string? uuid = null;
        string? rname = null;
        unowned HashTable<string,string>? table = null;

        if (!this.manager.is_extension_valid(plugin_name)) {
            warning("Not loading invalid plugin: %s", plugin_name);
            return;
        }
        if (initial_uuid == null) {
            uuid = LibUUID.new(UUIDFlags.LOWER_CASE|UUIDFlags.TIME_SAFE_TYPE);
        } else {
            uuid = initial_uuid;
        }

        if (!this.manager.is_extension_loaded(plugin_name)) {
            /* Request a load of the new guy */
            table = creating.lookup(plugin_name);
            if (table != null) {
                if (!table.contains(uuid)) {
                    table.insert(uuid, uuid);
                }
                return;
            }
            /* Looks insane but avoids copies */
            creating.insert(plugin_name, new HashTable<string,string>(str_hash, str_equal));
            table = creating.lookup(plugin_name);
            table.insert(uuid, uuid);
            this.manager.modprobe(plugin_name);
            return;
        }
        /* Already exists */
        Budgie.AppletInfo? info = this.manager.create_new_applet(plugin_name, uuid);
        if (info == null) {
            critical("Failed to load applet when we know it exists");
            return;
        }
        this.add_applet(info);
        return;
    }

    void add_pending(string uuid, string plugin_name)
    {
        string? rname = null;
        unowned HashTable<string,string>? table = null;

        if (!this.manager.is_extension_valid(plugin_name)) {
            warning("Not adding invalid plugin: %s %s", plugin_name, uuid);
            return;
        }

        if (!this.manager.is_extension_loaded(plugin_name)) {
            /* Request a load of the new guy */
            table = pending.lookup(plugin_name);
            if (table != null) {
                if (!table.contains(uuid)) {
                    table.insert(uuid, uuid);
                }
                return;
            }
            /* Looks insane but avoids copies */
            pending.insert(plugin_name, new HashTable<string,string>(str_hash, str_equal));
            table = pending.lookup(plugin_name);
            table.insert(uuid, uuid);
            this.manager.modprobe(plugin_name);
            return;
        }

        /* Already exists */
        Budgie.AppletInfo? info = this.manager.load_applet_instance(uuid, out rname);
        if (info == null) {
            critical("Failed to load applet when we know it exists");
            return;
        }
        this.add_applet(info);
    }

    public override void map()
    {
        base.map();
        placement();
    }

    public override void get_preferred_width(out int m, out int n)
    {
        int x, j;
        base.get_preferred_width(out x, out j);
        m = scr.width;
        n = scr.width;
    }
    public override void get_preferred_width_for_height(int h, out int m, out int n)
    {
        int x, j;
        base.get_preferred_width_for_height(h, out x, out j);
        m = scr.width;
        n = scr.width;
    }

    public override void get_preferred_height(out int m, out int n)
    {
        int x, j;
        base.get_preferred_height(out x, out j);
        m = scr.height;
        n = scr.height;
    }
    public override void get_preferred_height_for_width(int w, out int m, out int n)
    {
        int x, j;
        base.get_preferred_height_for_width(w, out x, out j);
        m = scr.height;
        n = scr.height;
    }

    public void set_expanded(bool expanded)
    {
        if (this.expanded == expanded) {
            return;
        }
        this.expanded = expanded;
        if (!expanded) {
            if (wm_proxy != null) {
                try {
                    this.wm_proxy.restore_focused();
                } catch (Error e) {
                    message("Error with wm_proxy: %s", e.message);
                }
            }
            scr = small_scr;
        } else {
            if (wm_proxy != null) {
                try {
                    this.wm_proxy.store_focused();
                } catch (Error e) {
                    message("Error with wm_proxy: %s", e.message);
                }
            }
            scr = orig_scr;
        }

        Gtk.Allocation alloc = Gtk.Allocation() {
            x = 0,
            y = 0,
            width = scr.width,
            height = scr.height
        };
        set_allocation(alloc);
        queue_resize();

        while (Gtk.events_pending()) {
            Gtk.main_iteration();
        }

        if (expanded) {
            Idle.add(()=> {
                if (get_window() != null) {
                    get_window().focus(Gdk.CURRENT_TIME);
                }
                present();
                return false;
            });
        }
    }

    void placement()
    {
        Budgie.set_struts(this, position, (intended_size - 5)*this.scale);
        switch (position) {
            case Budgie.PanelPosition.TOP:
                if (main_layout.valign != Gtk.Align.START) {
                    main_layout.valign = Gtk.Align.START;
                }
                set_gravity(Gdk.Gravity.NORTH_WEST);
                move(orig_scr.x, orig_scr.y);
                main_layout.child_set(shadow, "position", 1);
                break;
            default:
                if (main_layout.valign != Gtk.Align.END) {
                    main_layout.valign = Gtk.Align.END;
                }
                set_gravity(Gdk.Gravity.SOUTH_WEST);
                move(orig_scr.x, orig_scr.y+(orig_scr.height-intended_size));
                main_layout.child_set(shadow, "position", 0);
                break;
        }
    }

    private bool applet_at_start_of_region(Budgie.AppletInfo? info)
    {
        return (info.position == 0);
    }

    private bool applet_at_end_of_region(Budgie.AppletInfo? info)
    {
        return (info.position >= info.applet.get_parent().get_children().length() - 1);
    }

    private string? get_box_left(Budgie.AppletInfo? info)
    {
        unowned Gtk.Widget? parent = null;

        if ((parent = info.applet.get_parent()) == end_box) {
            return "center";
        } else if (parent == center_box) {
            return "start";
        } else {
            return null;
        }
    }

    private string? get_box_right(Budgie.AppletInfo? info)
    {
        unowned Gtk.Widget? parent = null;

        if ((parent = info.applet.get_parent()) == start_box) {
            return "center";
        } else if (parent == center_box) {
            return "end";
        } else {
            return null;
        }
    }

    public override bool can_move_applet_left(Budgie.AppletInfo? info)
    {
        if (!applet_at_start_of_region(info)) {
            return true;
        }
        if (get_box_left(info) != null) {
            return true;
        }
        return false;
    }

    public override bool can_move_applet_right(Budgie.AppletInfo? info)
    {
        if (!applet_at_end_of_region(info)) {
            return true;
        }
        if (get_box_right(info) != null) {
            return true;
        }
        return false;
    }

    void conflict_swap(Budgie.AppletInfo? info, int old_position)
    {
        unowned string key;
        unowned Budgie.AppletInfo? val;
        unowned Budgie.AppletInfo? conflict = null;
        var iter = HashTableIter<string,Budgie.AppletInfo?>(applets);

        while (iter.next(out key, out val)) {
            if (val.alignment == info.alignment && val.position == info.position && info != val) {
                conflict = val;
                break;
            }
        }

        if (conflict == null) {
            return;
        }

        conflict.position = old_position;
    }

    void budge_em_right(string alignment)
    {
        unowned string key;
        unowned Budgie.AppletInfo? val;
        var iter = HashTableIter<string,Budgie.AppletInfo?>(applets);

        while (iter.next(out key, out val)) {
            if (val.alignment == alignment) {
                val.position++;
            }
        }
    }

    void budge_em_left(string alignment, int after)
    {
        unowned string key;
        unowned Budgie.AppletInfo? val;
        var iter = HashTableIter<string,Budgie.AppletInfo?>(applets);

        while (iter.next(out key, out val)) {
            if (val.alignment == alignment) {
                if (val.position > after) {
                    val.position--;
                }
            }
        }
    }

    public override void move_applet_left(Budgie.AppletInfo? info)
    {
        string? new_home = null;
        int new_position = info.position;
        int old_position = info.position;

        if (!applet_at_start_of_region(info)) {
            new_position--;
            if (new_position < 0) {
                new_position = 0;
            }
            info.position = new_position;
            conflict_swap(info, old_position);
            applets_changed();
            return;
        }
        if ((new_home = get_box_left(info)) != null) {
            unowned Gtk.Box? new_parent = null;
            switch (info.alignment) {
                case "end":
                    new_parent = center_box;
                    break;
                case "center":
                    new_parent = start_box;
                    break;
                default:
                    new_parent = end_box;
                    break;
            }

            string old_home = info.alignment;
            uint len = new_parent.get_children().length();
            info.alignment = new_home;
            info.position = (int)len;
            budge_em_left(old_home, 0);
            applets_changed();
        }
    }

    public override void move_applet_right(Budgie.AppletInfo? info)
    {
        string? new_home = null;
        int new_position = info.position;
        int old_position = info.position;
        uint len;

        if (!applet_at_end_of_region(info)) {
            new_position++;
            len = info.applet.get_parent().get_children().length() - 1;
            if (new_position > len) {
                new_position = (int) len;
            }
            info.position = new_position;
            conflict_swap(info, old_position);
            applets_changed();
            return;
        }
        if ((new_home = get_box_right(info)) != null) {
            budge_em_right(new_home);
            info.alignment = new_home;
            info.position = 0;
            applets_changed();
        }
    }

    public override bool draw(Cairo.Context cr)
    {
        if (render_scale == 0.0) {
            return base.draw(cr);
        } else if (render_scale == 1.0) {
            return Gdk.EVENT_STOP;
        }

        Gtk.Allocation alloc;
        get_allocation(out alloc);
        var buffer = new Cairo.ImageSurface(Cairo.Format.ARGB32, alloc.width, alloc.height);
        var cr2 = new Cairo.Context(buffer);

        propagate_draw(get_child(), cr2);
        var d = (double) intended_size;
        var y = d * render_scale;

        /* Offset the buffer according to y-screen-edge */
        if (position == PanelPosition.TOP) {
            cr.set_source_surface(buffer, 0, -y);
        } else {
            cr.set_source_surface(buffer, 0, y);
        }
        cr.paint();

        return Gdk.EVENT_STOP;
    }

    /**
     * Specialist operation, perform a migration after we changed applet configurations
     * See: https://github.com/solus-project/budgie-desktop/issues/555
     */
    public void perform_migration(int current_migration_level)
    {
        if (current_migration_level != 0) {
            GLib.warning("Unknown migration level: %d", current_migration_level);
            return;
        }
        this.need_migratory = true;
        if (this.is_fully_loaded) {
            GLib.message("Performing migration to level %d", BUDGIE_MIGRATION_LEVEL);
            this.add_migratory();
        }
    }

    /**
     * Very simple right now. Just add the applets to the end of the panel
     */
    private bool add_migratory()
    {
        lock (need_migratory) {
            if (!need_migratory) {
                return false;
            }
            need_migratory = false;
            foreach (var new_applet in MIGRATION_1_APPLETS) {
                message("Adding migratory applet: %s", new_applet);
                add_new_applet_at(new_applet, end_box);
            }
        }
        return false;
    }
}

} // End namespace

/*
 * Editor modelines  -  https://www.wireshark.org/tools/modelines.html
 *
 * Local variables:
 * c-basic-offset: 4
 * tab-width: 4
 * indent-tabs-mode: nil
 * End:
 *
 * vi: set shiftwidth=4 tabstop=4 expandtab:
 * :indentSize=4:tabSize=4:noTabs=true:
 */
