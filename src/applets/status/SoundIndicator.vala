/*
 * This file is part of budgie-desktop
 * 
 * Copyright © 2015-2017 Budgie Desktop Developers
 * 
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

const string MIXER_NAME = "Budgie Volume Control";

public class SoundIndicator : Gtk.Bin
{

    /** Current image to display */
    public Gtk.Image widget { protected set; public get; }

    /** Our mixer */
    public Gvc.MixerControl mixer { protected set ; public get ; }

    /** Default stream */
    private Gvc.MixerStream? stream;

    /** EventBox for popover management */
    public Gtk.EventBox? ebox;

    /** GtkPopover in which to show a volume control */
    public Budgie.Popover popover;

    /** Display scale for le volume controls */
    private Gtk.Scale volume_scale;

    private double step_size;
    private ulong notify_id;

    /** Track the scale value_changed to prevent cross-noise */
    private ulong scale_id;
    private SoundSettingsManager? sound_settings = null;

    public SoundIndicator()
    {
        // Start off with at least some icon until we connect to pulseaudio */
        widget = new Gtk.Image.from_icon_name("audio-volume-muted-symbolic", Gtk.IconSize.MENU);
        ebox = new Gtk.EventBox();
        ebox.add(widget);
        ebox.margin = 0;
        ebox.border_width = 0;
        add(ebox);

        mixer = new Gvc.MixerControl(MIXER_NAME);
        mixer.state_changed.connect(on_state_change);
        mixer.default_sink_changed.connect(on_sink_changed);
        mixer.open();

        /* Sort out our popover */
        this.create_sound_popover();

        this.get_style_context().add_class("sound-applet");
        this.popover.get_style_context().add_class("sound-popover");

        sound_settings = new SoundSettingsManager();
        sound_settings.on_allow_volume_amp_changed.connect(on_allow_volume_amp_changed);

        /* Catch scroll wheel events */
        ebox.add_events(Gdk.EventMask.SCROLL_MASK);
        ebox.scroll_event.connect(on_scroll_event);
        show_all();
    }

    /**
     * Create the GtkPopover to display on primary click action, with an adjustable
     * scale
     */
    private void create_sound_popover()
    {
        popover = new Budgie.Popover(ebox);
        Gtk.Box? main_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        main_box.border_width = 6;
        Gtk.Box? popover_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        main_box.pack_start(popover_box, false, false, 0);
        popover.add(main_box);
        Gtk.Button? sub_button = new Gtk.Button.from_icon_name("list-remove-symbolic", Gtk.IconSize.BUTTON);
        Gtk.Button? plus_button = new Gtk.Button.from_icon_name("list-add-symbolic", Gtk.IconSize.BUTTON);

        /* - button */
        popover_box.pack_start(sub_button, false, false, 1);
        sub_button.clicked.connect(()=> {
            adjust_volume_increment(-step_size);
        });

        volume_scale = new Gtk.Scale.with_range(Gtk.Orientation.HORIZONTAL, 0, 100, 1);
        popover_box.pack_start(volume_scale, false, false, 0);

        /* Hook up the value_changed event */
        scale_id = volume_scale.value_changed.connect(on_scale_changed);

        /* + button */
        popover_box.pack_start(plus_button, false, false, 1);
        plus_button.clicked.connect(()=> {
            adjust_volume_increment(+step_size);
        });

        /* Refine visual appearance of the scale.. */
        volume_scale.set_draw_value(false);
        volume_scale.set_size_request(140, -1);

        /* Flat buttons only pls :) */
        sub_button.get_style_context().add_class("flat");
        sub_button.get_style_context().add_class("image-button");
        plus_button.get_style_context().add_class("flat");
        plus_button.get_style_context().add_class("image-button");

        /* Focus ring is ugly and unnecessary */
        sub_button.set_can_focus(false);
        plus_button.set_can_focus(false);
        volume_scale.set_can_focus(false);
        volume_scale.set_inverted(false);

        var sep = new Gtk.Separator(Gtk.Orientation.HORIZONTAL);
        main_box.pack_start(sep, false, false, 1);

        var button = new Gtk.Button.with_label(_("Sound settings"));
        button.get_child().set_halign(Gtk.Align.START);
        button.get_style_context().add_class(Gtk.STYLE_CLASS_FLAT);
        button.clicked.connect(open_sound_settings);
        main_box.pack_start(button, false, false, 0);

        popover.get_child().show_all();
    }

    void on_sink_changed(uint id)
    {
        set_default_mixer();
    }

    void set_default_mixer()
    {
        if (stream != null) {
            SignalHandler.disconnect(stream, notify_id);
        }
        
        stream = mixer.get_default_sink();
        notify_id = stream.notify.connect(on_notify);
        update_volume();
    }

    void on_notify(Object? o, ParamSpec? p)
    {
        if (p.name == "volume" || p.name == "is-muted") {
            update_volume();
        }
    }

    /**
     * Called when something changes on the mixer, i.e. we connected
     * This is where we hook into the stream for changes
     */
    protected void on_state_change(uint new_state)
    {
        if (new_state == Gvc.MixerControlState.READY) {
            set_default_mixer();
        }
    }

    /**
     * Update from scroll events. turn volume up + down.
     */
    protected bool on_scroll_event(Gdk.EventScroll event)
    {
        return_val_if_fail(stream != null, false);

        uint32 vol = stream.get_volume();
        var orig_vol = vol;

        switch (event.direction) {
            case Gdk.ScrollDirection.UP:
                vol += (uint32)step_size;
                break;
            case Gdk.ScrollDirection.DOWN:
                vol -= (uint32)step_size;
                // uint. im lazy :p
                if (vol > orig_vol) {
                    vol = 0;
                }
                break;
            default:
                // Go home, you're drunk.
                return false;
        }

        var vol_max = get_max_volume();
        vol = uint32.min(vol, (uint32)vol_max);

        SignalHandler.block(volume_scale, scale_id);
        if (stream.set_volume(vol)) {
            Gvc.push_volume(stream);
        }
        SignalHandler.unblock(volume_scale, scale_id);

        return true;
    }

    void on_allow_volume_amp_changed(bool value)
    {
        update_volume();
    }

    double get_max_volume()
    {
        if (sound_settings.allow_volume_amp) {
            return mixer.get_vol_max_amplified();
        } else {
            return mixer.get_vol_max_norm();
        }
    }

    /**
     * Update our icon when something changed (volume/mute)
     */
    protected void update_volume()
    {
        var vol_max = get_max_volume();
        var vol = stream.get_volume();

        /* Same maths as computed by volume.js in gnome-shell, carried over
         * from C->Vala port of budgie-panel */
        int n = (int) Math.floor(3*vol/vol_max)+1;
        string image_name;

        // Work out an icon
        if (stream.get_is_muted() || vol <= 0) {
            image_name = "audio-volume-muted-symbolic";
        } else {
            switch (n) {
                case 1:
                    image_name = "audio-volume-low-symbolic";
                    break;
                case 2:
                    image_name = "audio-volume-medium-symbolic";
                    break;
                default:
                    image_name = "audio-volume-high-symbolic";
                    break;
            }
        }
        widget.set_from_icon_name(image_name, Gtk.IconSize.MENU);

        // Each scroll increments by 5%, much better than units..
        step_size = vol_max / 20;

        // This usually goes up to about 150% (152.2% on mine though.)
        var pct = ((float)vol / (float)vol_max)*100;
        var ipct = (uint)pct;
        widget.set_tooltip_text(@"$ipct%");

        /* We're ignoring anything beyond our vol_max.. */
        SignalHandler.block(volume_scale, scale_id);
        volume_scale.set_range(0, vol_max);
        vol = uint32.min(vol, (uint32)vol_max);
        volume_scale.set_value(vol);

        volume_scale.get_adjustment().set_page_increment(step_size);
        SignalHandler.unblock(volume_scale, scale_id);

        show_all();
        queue_draw();
    }

    /**
     * The scale changed value - update the stream volume to match
     */
    private void on_scale_changed()
    {
        if (stream == null || mixer == null) {
            return;
        }
        double scale_value = volume_scale.get_value();

        /* Avoid recursion ! */
        SignalHandler.block(volume_scale, scale_id);
        if (stream.set_volume((uint32)scale_value)) {
            Gvc.push_volume(stream);
        }
        SignalHandler.unblock(volume_scale, scale_id);
    }

    /**
     * Adjust the volume by a given +/- increment and bounds limit it
     */
    private void adjust_volume_increment(double increment)
    {
        if (stream == null || mixer == null) {
            return;
        }
        int32 vol = (int32)stream.get_volume();
        int32 vol_max = (int32)get_max_volume();
        vol += (int32)increment;

        vol = vol.clamp(0, vol_max);

        SignalHandler.block(volume_scale, scale_id);
        if (stream.set_volume((uint32)vol)) {
            Gvc.push_volume(stream);
        }
        SignalHandler.unblock(volume_scale, scale_id);
    }


    void open_sound_settings() {
        popover.hide();

        var app_info = new DesktopAppInfo("gnome-sound-panel.desktop");

        if (app_info == null) {
            return;
        }

        try {
            app_info.launch(null, null);
        } catch (Error e) {
            message("Unable to launch gnome-sound-panel.desktop: %s", e.message);
        }
    }

} // End class
