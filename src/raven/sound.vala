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

public class SoundWidget : Gtk.Box
{

    private Gtk.Scale? scale = null;
    private ulong scale_id = 0;

    private Gvc.MixerControl? mixer = null;

    private Gtk.Switch? output_switch = null;
    private ulong output_switch_id = 0;
    private Gtk.Box? output_box = null;
    private Gtk.RadioButton? output_leader = null;
    private HashTable<uint,Gtk.RadioButton?> outputs;
    private Gvc.MixerStream? output_stream = null;
    private ulong output_notify_id = 0;

    private Gtk.Switch? input_switch = null;
    private ulong input_switch_id = 0;
    private Gtk.Box? input_box = null;
    private Gtk.RadioButton? input_leader = null;
    private HashTable<uint,Gtk.RadioButton?> inputs;
    private Gvc.MixerStream? input_stream = null;
    private ulong input_notify_id = 0;
    private SoundSettingsManager? sound_settings = null;

    private Budgie.HeaderWidget? header = null;

    public SoundWidget()
    {
        Object(orientation: Gtk.Orientation.VERTICAL);

        get_style_context().add_class("audio-widget");

        sound_settings = new SoundSettingsManager();

        /* TODO: Fix icon */
        scale = new Gtk.Scale.with_range(Gtk.Orientation.HORIZONTAL, 0, 100, 10);
        scale.set_draw_value(false);
        scale.value_changed.connect(on_output_scale_change);
        header = new Budgie.HeaderWidget("", "audio-volume-muted-symbolic", false, scale);

        var expander = new Budgie.RavenExpander(header);
        pack_start(expander, false, false);

        var ebox = new Gtk.EventBox();
        ebox.get_style_context().add_class("raven-background");
        expander.add(ebox);

        outputs = new HashTable<uint,Gtk.RadioButton?>(direct_hash,direct_equal);
        inputs = new HashTable<uint,Gtk.RadioButton?>(direct_hash,direct_equal);
        mixer = new Gvc.MixerControl("Budgie Volume Control");
        mixer.state_changed.connect(on_state_changed);
        mixer.output_added.connect(on_output_added);
        mixer.output_removed.connect(on_output_removed);
        mixer.input_added.connect(on_input_added);
        mixer.input_removed.connect(on_input_removed);
        mixer.default_sink_changed.connect(on_sink_changed);
        mixer.default_source_changed.connect(on_source_changed);

        var main_layout = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        main_layout.margin_top = 6;
        main_layout.margin_bottom = 6;
        main_layout.margin_start = 12;
        main_layout.margin_end = 12;

        ebox.add(main_layout);

        /* row containing extra sound options */
        build_sound_options_row(main_layout);

        /* Output row */
        var row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        var label = new Gtk.Label(_("Output"));
        label.get_style_context().add_class("heading");
        row.pack_start(label, true, true, 0);
        label.halign = Gtk.Align.START;

        output_switch = new Gtk.Switch();
        output_switch.active = false;
        output_switch_id = output_switch.notify["active"].connect(on_output_mute_changed);

        row.pack_end(output_switch, false, false, 0);
        main_layout.pack_start(row, false, false, 0);
        output_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        main_layout.pack_start(output_box, false, false, 0);
        output_box.margin_bottom = 6;

        /* Input row */
        row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        label = new Gtk.Label(_("Input"));
        label.get_style_context().add_class("heading");
        row.pack_start(label, true, true, 0);
        label.halign = Gtk.Align.START;

        input_switch = new Gtk.Switch();
        input_switch.active = false;
        input_switch_id = input_switch.notify["active"].connect(on_input_mute_changed);

        row.pack_end(input_switch, false, false, 0);
        main_layout.pack_start(row, false, false, 0);
        input_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        main_layout.pack_start(input_box, false, false, 0);
        input_box.margin_bottom = 6;

        expander.expanded = true;

        mixer.open();
    }

    void build_sound_options_row(Gtk.Box main_layout)
    {

        /* Root box that contains set of options and label */
        var root = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        var label = new Gtk.Label(_("Sound Options"));
        var separator = new Gtk.Separator(Gtk.Orientation.HORIZONTAL);

        label.get_style_context().add_class("heading");
        label.halign = Gtk.Align.START;
        root.pack_start(label, true, true, 0);
        root.pack_end(separator, true, true, 0);
        separator.margin_top = 12;
        separator.margin_bottom = 12;


        /* Box for grouping available sound options */
        var options_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        options_box.margin_left = 12;

        /* Option for allowing sound greater than 100% */
        var allow_volume_amp_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        var allow_volume_amp_label = new Gtk.Label(_("Allow volume louder than 100%"));
        var allow_volume_amp_switch = new Gtk.Switch();
        allow_volume_amp_switch.active = sound_settings.allow_volume_amp;
        allow_volume_amp_row.pack_start(allow_volume_amp_label, true, true, 0);
        allow_volume_amp_row.pack_end(allow_volume_amp_switch, false, false, 0);
        allow_volume_amp_switch.state_set.connect(on_max_volume_changed);

        /* Add all options */
        options_box.pack_start(allow_volume_amp_row, false, false, 0);

        root.pack_start(options_box, false, false, 0);
        main_layout.pack_start(root, false, false, 0);
    }

    /* Changed the max volume allowed */
    public bool on_max_volume_changed(bool state)
    {
        sound_settings.allow_volume_amp = state;
        // update the scale range, volume and volume icon
        update_volume();

        // run the default state change handler
        return false;
    }

    /**
     * New volume from our scale
     */
    void on_output_scale_change()
    {
        if (output_stream == null) {
            return;
        }
        if (output_stream.set_volume((uint32)scale.get_value())) {
            Gvc.push_volume(output_stream);
        }
    }

    /**
     * Allow users to mute
     */
    void on_output_mute_changed()
    {
        if (output_stream == null) {
            return;
        }
        output_stream.change_is_muted(!output_switch.active);
    }

    /**
     * Allow users to mute mic
     */
    void on_input_mute_changed()
    {
        if (input_stream == null) {
            return;
        }
        input_stream.change_is_muted(!input_switch.active);
    }

    /* Microphone changed */
    void on_source_changed(uint id)
    {
        var stream = mixer.get_default_source();
        if (stream == this.input_stream) {
            return;
        }
        {
            var device = mixer.lookup_device_from_stream(stream);
            var did = device.get_id();
            var check = inputs.lookup(did);

            if (check != null) {
                SignalHandler.block_by_func((void*)check, (void*)on_input_selected, this);
                check.active = true;
                SignalHandler.unblock_by_func((void*)check, (void*)on_input_selected, this);
            }
        }

        if (this.input_stream != null) {
            this.input_stream.disconnect(this.input_notify_id);
            input_notify_id = 0;
        }
        input_notify_id = stream.notify.connect((n,p)=> {
            if (p.name == "is-muted") {
                update_input();
            }
        });

        this.input_stream = stream;

        update_input();
    }

    /** Update mute status on input stream */
    void update_input()
    {
        if (this.input_stream == null) {
            return;
        }

        if (input_switch_id > 0) {
            SignalHandler.block(input_switch, input_switch_id);
            input_switch.active = !input_stream.is_muted;
            SignalHandler.unblock(input_switch, input_switch_id);
        } else {
            input_switch.active = !input_stream.is_muted;
        }
    }

    /* Somewhere new for where to put sound to */
    void on_sink_changed(uint id)
    {
        var stream = mixer.get_default_sink();
        if (stream == this.output_stream) {
            return;
        }

        {
            var device = mixer.lookup_device_from_stream(stream);
            var did = device.get_id();
            var check = outputs.lookup(did);

            if (check != null) {
                SignalHandler.block_by_func((void*)check, (void*)on_output_selected, this);
                check.active = true;
                SignalHandler.unblock_by_func((void*)check, (void*)on_output_selected, this);
            }
        }

        if (this.output_stream != null) {
            this.output_stream.disconnect(this.output_notify_id);
            output_notify_id = 0;
        }
        output_notify_id = stream.notify.connect((n,p)=> {
            if (p.name == "volume" || p.name == "is-muted") {
                update_volume();
            }
        });

        this.output_stream = stream;

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

    void update_volume()
    {
        if (output_switch_id > 0) {
            SignalHandler.block(output_switch, output_switch_id);
            output_switch.active = !output_stream.is_muted;
            SignalHandler.unblock(output_switch, output_switch_id);
        } else {
            output_switch.active = !output_stream.is_muted;
        }

        var vol_max = get_max_volume();
        var vol = double.min(output_stream.get_volume(), vol_max);

        /* Same maths as computed by volume.js in gnome-shell, carried over
         * from C->Vala port of budgie-panel */
        int n = (int) Math.floor(3*vol/vol_max)+1;
        string image_name;

        // Work out an icon
        if (output_stream.get_is_muted() || vol <= 0) {
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
        header.icon_name = image_name;

        /* Each scroll increments by 5%, much better than units..*/
        var step_size = vol_max / 20;
        if (scale_id > 0) {
            SignalHandler.block(scale, scale_id);
        }
        scale.set_range(0, vol_max);
        scale.set_value(vol);
        scale.set_increments(step_size, step_size);
        if (scale_id > 0) {
            SignalHandler.unblock(scale, scale_id);
        }
    }

    void on_output_selected(Gtk.ToggleButton? btn)
    {
        if (!btn.get_active()) {
            return;
        }
        uint id = btn.get_data("output_id");
        var device = mixer.lookup_output_id(id);
        if (device == null) {
            warning("Output selected does not exist! %u", id);
            return;
        }
        mixer.change_output(device);
    }

    void on_input_selected(Gtk.ToggleButton? btn)
    {
        if (!btn.get_active()) {
            return;
        }
        uint id = btn.get_data("input_id");
        var device = mixer.lookup_input_id(id);
        if (device == null) {
            warning("Input selected does not exist! %u", id);
            return;
        }
        mixer.change_input(device);
    }

    /* New available output */
    void on_output_added(uint id)
    {
        if (outputs.contains(id)) {
            return;
        }
        var device = this.mixer.lookup_output_id(id);

        if (device.card == null) {
            return;
        }

        var card = device.card as Gvc.MixerCard;
        var check = new Gtk.RadioButton.with_label_from_widget(this.output_leader, "%s - %s".printf(device.description, card.name));
        (check.get_child() as Gtk.Label).set_ellipsize(Pango.EllipsizeMode.END);
        (check.get_child() as Gtk.Label).max_width_chars = 30;
        check.set_data("output_id", id);
        check.toggled.connect(on_output_selected);
        output_box.pack_start(check, false, false, 0);
        check.show_all();

        if (this.output_leader == null) {
            this.output_leader = check;
            check.margin_top = 3;
        }

        outputs.insert(id, check);
    }

    /* New available input */
    void on_input_added(uint id)
    {
        if (inputs.contains(id)) {
            return;
        }
        var device = this.mixer.lookup_input_id(id);

        if (device.card == null) {
            return;
        }

        var card = device.card as Gvc.MixerCard;
        var check = new Gtk.RadioButton.with_label_from_widget(this.input_leader, "%s - %s".printf(device.description, card.name));
        (check.get_child() as Gtk.Label).set_ellipsize(Pango.EllipsizeMode.END);
        (check.get_child() as Gtk.Label).max_width_chars = 30;
        check.set_data("input_id", id);
        check.toggled.connect(on_input_selected);
        input_box.pack_start(check, false, false, 0);
        check.show_all();

        if (this.input_leader == null) {
            this.input_leader = check;
            check.margin_top = 3;
        }

        inputs.insert(id, check);
    }

    void on_output_removed(uint id)
    {
        Gtk.RadioButton? btn = outputs.lookup(id);
        if (btn == null) {
            warning("Removing id we don\'t know about: %u", id);
            return;
        }
        outputs.steal(id);
        btn.destroy();
    }

    void on_input_removed(uint id)
    {
        Gtk.RadioButton? btn = inputs.lookup(id);
        if (btn == null) {
            warning("Removing id we don\'t know about: %u", id);
            return;
        }
        inputs.steal(id);
        btn.destroy();
    }

    /* Update defaults, not yet implemented */
    void update_mixers()
    {

    }

    void on_state_changed(uint state)
    {
        switch (state) {
            case Gvc.MixerControlState.READY:
                /* We ready. */
                update_mixers();
                break;
            default:
                break;
        }
    }

} // End class

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
