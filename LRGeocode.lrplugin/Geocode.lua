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
local LrProgressScope = import("LrProgressScope")

local catalog = LrApplication.activeCatalog()
local selected_photos = catalog:getTargetPhotos()
local photos_to_update = {}
local all_addresses = {}
local new_addresses = {}
local new_address_count = 0

local gps_data = {}
local location_data = {}

local mainProgress = {}

function url_encode(str)
  str = str:gsub("\n", "\r\n")
  str = str:gsub("([^%w ])",
      function (c) return string.format("%%%02X", string.byte(c)) end)
  str = str:gsub(" ", "+")
  return str  
end

function build_address(photo)
  local location = location_data[photo].location
  local city = location_data[photo].city
  local state = location_data[photo].stateProvince
  local country = location_data[photo].country

  if country and country ~= "" and state and state ~= "" then
    local address = state .. ", " .. country
    if city and city ~= "" then
      address = city .. ", " .. address
    end
    if location and location ~= "" then
      address = location .. ", " .. address
    end

    return address
  end

  return nil
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

function scanForAddresses(context)
  local progress = LrProgressScope({
    caption = "Scanning photos for new addresses",
    functionContext = context,
    parent = mainProgress,
    parentEndRange = 0.1,
  })

  for i = 1, #selected_photos do
    local gps = gps_data[selected_photos[i]].gps

    local address = build_address(selected_photos[i])

    if address then
      if gps == nil then
        table.insert(photos_to_update, selected_photos[i])
      end

      if all_addresses[address] == nil then
        all_addresses[address] = { address = address, gps = gps }
        if gps == nil then
          new_addresses[address] = all_addresses[address]
          new_address_count = new_address_count + 1
        end
      elseif gps and all_addresses[address].gps == nil then
        all_addresses[address].gps = gps
        new_addresses[address] = nil
        new_address_count = new_address_count - 1
      end
    end

    progress:setPortionComplete(i, #selected_photos)
    LrTasks.yield()

    if mainProgress:isCanceled() then
      return false
    end
  end

  return true
end

function geocodeAddresses(context)
  local progress = LrProgressScope({
    caption = "Geocoding addresses",
    functionContext = context,
    parent = mainProgress,
    parentEndRange = 0.9,
  })

  local pos = 0
  for address, data in pairs(new_addresses) do
    pos = pos + 1
    urladdress = url_encode(address)
    local url = "http://maps.googleapis.com/maps/api/geocode/xml?address=" .. urladdress .. "&sensor=false"
    local success, results = LrTasks.pcall(parse_georesult, url)
    if success then
      if #results > 0 then
        local result = LrFunctionContext.callWithContext("selectAddress", function(context, results)
          local f = LrView.osFactory()
          local properties = LrBinding.makePropertyTable(context)
          properties.result = 1

          local ui = {
            spacing = f:control_spacing(),
            bind_to_object = properties,
            f:static_text {
              title = "Select the correct address for " .. address .. ":"
            },
            f:radio_button {
              title = "None of these addresses are correct",
              value = LrView.bind "result",
              checked_value = 0,
            }
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
            mainProgress:cancel()
            return nil
          end

          if properties.result == 0 then
            return nil
          end

          return results[properties.result]
        end, results)

        if result then
          data.address = result.address
          data.gps = result.gps
        end
      end
    end

    progress:setPortionComplete(pos, new_address_count)
    LrTasks.yield()

    if mainProgress:isCanceled() then
      return false
    end
  end

  return true
end

function performUpdates(context)
  local progress = LrProgressScope({
    caption = "Applying GPS data",
    functionContext = context,
    parent = mainProgress,
    parentEndRange = 1,
  })

  local change_count = 0

  for i = 1, #photos_to_update do
    local address = build_address(photos_to_update[i])

    if all_addresses[address].gps then
      photos_to_update[i]:setRawMetadata("gps", all_addresses[address].gps)
      change_count = change_count + 1
    end

    progress:setPortionComplete(i, #photos_to_update)
    LrTasks.yield()

    if mainProgress:isCanceled() then
      error("Operation canceled")
    end
  end

  LrDialogs.message("GPS data updated for " .. change_count .. " photos")
end

function updatePhotos(context)
  catalog:withWriteAccessDo("Geocoding Photos", performUpdates)
end

LrTasks.startAsyncTask(function()
  if #selected_photos == 0 then
    LrDialogs.message("No photos selected")
  end

  LrFunctionContext.callWithContext("mainTask", function(context)
    mainProgress = LrProgressScope({
      title = "Geocoding photos",
      functionContext = context,
    })
    mainProgress:setCancelable(true)

    gps_data = catalog:batchGetRawMetadata(selected_photos, { "gps", })

    if mainProgress:isCanceled() then
      return
    end
    mainProgress:setPortionComplete(2, 100)

    location_data = catalog:batchGetFormattedMetadata(selected_photos, { "location", "city", "stateProvince", "country", })

    if mainProgress:isCanceled() then
      return
    end
    mainProgress:setPortionComplete(5, 100)

    if LrFunctionContext.callWithContext("scanForAddresses", scanForAddresses) == false
       or mainProgress:isCanceled() then
      return
    end

    if #photos_to_update == 0 then
      LrDialogs.message("All photos with location information already have GPS data")
      return
    end

    mainProgress:setPortionComplete(10, 100)

    if new_address_count > 0 then
      if LrFunctionContext.callWithContext("geocodeAddresses", geocodeAddresses) == false
         or mainProgress:isCanceled() then
        return
      end
    end

    mainProgress:setPortionComplete(90, 100)

    updatePhotos()
  end)
end)
