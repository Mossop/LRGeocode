--[[----------------------------------------------------------------------------
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this file,
You can obtain one at http://mozilla.org/MPL/2.0/.
------------------------------------------------------------------------------]]

return {
	LrSdkVersion = 3.0,
	LrSdkMinimumVersion = 3.0, -- minimum SDK version required by this plug-in

	LrToolkitIdentifier = "com.fractalbrew.lrgeocode",

	LrPluginName = LOC "$$$/LRGeocode/PluginName=LRGeocode",
	LrPluginInfoUrl = "http://www.fractalbrew.com/labs/lrgeocode",

  LrLibraryMenuItems = { title = LOC "$$$/LRGeocode/MenuItem=&Geocode...",
                         file = "Geocode.lua",
                         enabledWhen = "anythingSelected", },

	VERSION = { major=0, minor=1, revision=0, build=0, },
}
