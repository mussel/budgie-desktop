/*
 * This file is part of budgie-desktop
 *
 * Copyright © 2017 Fernando Mussel
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

public class SoundSettingsManager : GLib.Object
{

    private GLib.Settings settings;
    const string SCHEMA_NAME = "com.solus-project.budgie";
    const string SETTING_ALLOW_VOLUME_AMP = "sound-allow-volume-amp";

    public SoundSettingsManager()
    {
        settings = new GLib.Settings(SCHEMA_NAME);
        settings.changed.connect(on_settings_changed);
    }

    public signal void on_allow_volume_amp_changed(bool value);

    public bool allow_volume_amp {
        get {
                return settings.get_boolean(SETTING_ALLOW_VOLUME_AMP);
            }

        set {
                settings.set_boolean(SETTING_ALLOW_VOLUME_AMP, value);
            }
    }

    private void on_settings_changed(string key)
    {
        // we only have one setting for now. Just call our signal
        on_allow_volume_amp_changed(allow_volume_amp);
    }
}
