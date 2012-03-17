--[[----------------------------------------------------------------------------
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this file,
You can obtain one at http://mozilla.org/MPL/2.0/.
------------------------------------------------------------------------------]]

local LrApplication = import("LrApplication")
local LrDialogs = import("LrDialogs")
local LrView = import("LrView")
local LrBinding = import "LrBinding"
local LrFunctionContext = import "LrFunctionContext"
local LrTasks = import("LrTasks")
local LrHttp = import("LrHttp")
local LrXml = import("LrXml")

local catalog = LrApplication.activeCatalog()
local photos = catalog:getTargetPhotos()

function url_encode(str)
  str = str:gsub("\n", "\r\n")
  str = str:gsub("([^%w ])",
      function (c) return string.format("%%%02X", string.byte(c)) end)
  str = str:gsub(" ", "+")
  return str  
end

function get_children(element, name)
  local results = {}

  for i = 1, element:childCount() do
    local child = element:childAtIndex(i)
    if child:name() == name then
      table.insert(results, child)
    end
  end

  return results
end

function get_child_element(element, name)
  local elements = get_children(element, name)
  if #elements == 0 then
    error("Invalid XML: No " .. name .. " element")
  elseif #elements > 1 then
    error("Invalid XML: Too many " .. name .. " elements")
  else
    return elements[1]
  end
end

function get_child_text(element, name)
  return get_child_element(element, name):text()
end

function parse_georesult(url)
  local body, headers = LrHttp.get(url)
  if body then
    local success, xml = LrTasks.pcall(LrXml.parseXml, body)
    if success then
      local status = get_child_text(xml, "status")
      if status ~= "OK" and status ~= "ZERO_RESULTS" then
        error("The geocoding API returned an error: " .. status)
      end

      local results = {}
      local result_elements = get_children(xml, "result")
      for i = 1, #result_elements do
        result = {}
        result.address = get_child_text(result_elements[i], "formatted_address")
        result.gps = {}
        local geometry = get_child_element(result_elements[i], "geometry")
        local location = get_child_element(geometry, "location")
        result.gps.latitude = tonumber(get_child_text(location, "lat"))
        result.gps.longitude = tonumber(get_child_text(location, "lng"))

        table.insert(results, result)
      end

      return results
    else
      error("There was an error parsing the geocoding API result")
    end
  else
    error("There was an error accessing the geocoding API: " .. headers.error.name)
  end
end

GeoCode = {}

function GeoCode.scanImages()
  if #photos == 1 then
    local photo = photos[1]

    local gps = photo:getRawMetadata("gps")
    if gps then
      return
    end

    local location = photo:getFormattedMetadata("location")
    local city = photo:getFormattedMetadata("city")
    local state = photo:getFormattedMetadata("stateProvince")
    local country = photo:getFormattedMetadata("country")

    if country == nil then
      return
    end

    local address = country
    if state then
      address = state .. ", " .. address
    end
    if city then
      address = city .. ", " .. address
    end
    if location then
      address = location .. ", " .. address
    end

    urladdress = url_encode(address)
    local url = "http://maps.googleapis.com/maps/api/geocode/xml?address=" .. urladdress .. "&sensor=false"
    local success, results = LrTasks.pcall(parse_georesult, url)
    if success then
      if #results == 0 then
        return
      end

      local result = results[1]
      
      if #results > 1 then
        result = LrFunctionContext.callWithContext("selectAddress", function(context, results)
          local f = LrView.osFactory()
          local properties = LrBinding.makePropertyTable(context)
          properties.result = 1

          local ui = {
            spacing = f:control_spacing(),
            bind_to_object = properties,
            f:static_text {
              title = "Multiple matches were found for " .. address
            },
            f:static_text {
              title = "Select the correct address:"
            },
          }

          for i = 1, #results do
            table.insert(ui, f:radio_button {
              title = results[i].address,
              value = LrView.bind "result",
              checked_value = i,
            })
          end

          local answer = LrDialogs.presentModalDialog({
            title = "Select correct address",
            contents = f:column(ui),
          })

          if answer ~= "ok" then
            return nil
          end

          return results[properties.result]
        end, results)
      end

      if result == nil then
        return
      end

      catalog:withWriteAccessDo("Geocode Photo", function()
        photo:setRawMetadata("gps", result.gps)
      end) 
    else
      LrDialogs.message(results)
    end
  else
    LrDialogs.message("Can only geocode one photo at a time")
  end
end

LrTasks.startAsyncTask(GeoCode.scanImages)
