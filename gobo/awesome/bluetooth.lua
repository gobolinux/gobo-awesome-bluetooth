
local bluetooth = {}

local gears = require("gears")
local timer = gears.timer or timer
local mouse = mouse
local awful = require("awful")
local wibox = require("wibox")
local beautiful = require("beautiful")
local spawn = require("awful.spawn")
local lgi = require("lgi")
local cairo = lgi.require("cairo")

--------------------------------------------------------------------------------
-- Global state
--------------------------------------------------------------------------------

local BLUETOOTHCTL_SLOW = "pidof bluetoothd &>/dev/null && bluetoothctl --timeout 5"
local BLUETOOTHCTL_FAST = "pidof bluetoothd &>/dev/null && bluetoothctl"

local bt_controllers
local bt_controller -- default bt controller

--------------------------------------------------------------------------------
-- Draw icon
--------------------------------------------------------------------------------

local function draw_icon(surface, state, connected)

   local b = state / 100

   local cr = cairo.Context(surface)

   local gc = b -- * 0.8 + 0.2
   
   cr:set_line_width(8)
   if connected then
      cr:set_source_rgb(1, 0.75, 0.3)
   else
      cr:set_source_rgb(gc * 0.84, gc * 0.89, gc * 0.89)
   end
   cr:move_to(25, 33)
   cr:line_to(75, 66)
   cr:line_to(50, 85)
   cr:line_to(50, 15)
   cr:line_to(75, 33)
   cr:line_to(25, 66)
   cr:stroke()
   --glow_rectangle(cr, 10, 10, 80, 80, gc, gc, gc * 0.8, 1.0, 5 + (b * 5))
end

local function get_icon(state, connected)
   local image = cairo.ImageSurface("ARGB32", 100, 100)
   draw_icon(image, state, connected)
   return image
end

local function update_icon(widget, state)
   widget:set_image(get_icon(state))
end

local icons = {}
for i = 50, 100, 10 do
   table.insert(icons, get_icon(i))
end
for i = #icons - 1, 2, -1 do
   table.insert(icons, icons[i])
end

--------------------------------------------------------------------------------
-- Utils for reading data
--------------------------------------------------------------------------------

local function pread(cmd)
   local pd = io.popen("LANG=C " .. cmd, "r")
   if not pd then
      return ""
   end
   local data = pd:read("*a")
   pd:close()
   return data
end

local run = awful.spawn and awful.spawn.with_shell or awful.util.spawn_with_shell

--------------------------------------------------------------------------------
-- Bluetooth logic
--------------------------------------------------------------------------------

local function get_bt_controllers()
   local data = pread(BLUETOOTHCTL_FAST .. " list")
   local items = {}
   for mac, rest in data:gmatch("Controller ([^%s]+)( [^\n]*)\n") do
      local item = { mac = mac }
      if rest:match("%[default%]") then
         item.default = true
         items.default = item
      end
      table.insert(items, item)
   end
   return items
end

local function get_bt_status()
   local data = pread(BLUETOOTHCTL_FAST .. " show " .. bt_controller.mac)
   local info = {}
   for k,v in data:gmatch("\n%s*([^:]*): ([^\n]*)") do
      info[k:lower()] = v
   end
   return info
end

local function get_bt_info(device)
   local data = pread(BLUETOOTHCTL_FAST .. " info " .. device)
   local info = {}
   for k,v in data:gmatch("\n%s*([^:]*): ([^\n]*)") do
      info[k:lower()] = v
   end
   return info
end

--local function disconnect()
--   run("bluetooth disconnect")
--end
--
--local function forget(essid)
--   run("bluetooth forget '"..essid:gsub("'", "'\\''").."'")
--end

--------------------------------------------------------------------------------
-- Widget code
--------------------------------------------------------------------------------

local function compact_entries(entries)
   local limit = 20
   if #entries > limit then
      local submenu = {}
      for i = limit + 1, #entries do
         table.insert(submenu, entries[i])
         entries[i] = nil
      end
      compact_entries(submenu)
      table.insert(entries, { "More...", submenu } )
   end
end

function bluetooth.new()
   local widget = wibox.widget.imagebox()
   local menu
   local menu_fn
   
   local bluetoothd_running = pread("pidof bluetoothd")
   if bluetoothd_running == "" then
      return widget
   end

   bt_controllers = get_bt_controllers()

   if #bt_controllers == 0 then
      return widget
   end
   
   bt_controller = bt_controllers.default
   
   if not bt_controller then
      return widget
   end
   
   local is_scanning = function() return false end
   local is_connecting = function() return false end

   local function animated_operation(args)
      local cmd = args.command
      local popup_menu = args.popup_menu_when_done or false
      if not cmd then return end
      local waiting
      local is_waiting = function()
         if not waiting then return false end
         if waiting() ~= true then
            return true
         end
         waiting = nil
         return false
      end
      return function()
         if is_waiting() then
            return is_waiting
         end
         do
            local done = false
            waiting = function()
               return done
            end
            spawn.easy_async(cmd, function()
               done = true
            end)
         end
         local frames = args.frames or icons
         local step = 1
         local animation_timer = timer({timeout=0.125})
         local function animate()
            if is_waiting() then
               widget:set_image(frames[step])
               step = step + 1
               if step == #frames + 1 then step = 1 end
            else
               animation_timer:stop()
               if popup_menu then
                  if menu then
                     menu:hide()
                     menu = nil
                  end
                  menu_fn(true)
               end
            end
         end
         animation_timer:connect_signal("timeout", animate)
         animation_timer:start()
         return is_waiting
      end
   end
   
   local rescan = animated_operation { command = BLUETOOTHCTL_SLOW .. " scan on", popup_menu_when_done = true }

   local function pair(device)
      return animated_operation { command =  BLUETOOTHCTL_SLOW .. " pair " .. device .. "; bluetoothctl trust " .. device } ()
   end

   local function connect(device)
      return animated_operation { command =  BLUETOOTHCTL_SLOW .. " connect " .. device } ()
   end

   local function disconnect(device)
      return animated_operation { command =  BLUETOOTHCTL_SLOW .. " disconnect " .. device } ()
   end
   
   local status = {}
   
   local function update()
      if is_scanning() or is_connecting() then
         return
      end
      
      status = get_bt_status()
      
      if status.powered == "yes" then
         update_icon(widget, 100)
      else
         update_icon(widget, 50)
      end
   end

   local function set_entries_size(entries)
      local len = 10
      for _, entry in ipairs(entries) do
         len = math.max(len, (#entry[1] + 1) * 10 )
      end
      entries.theme = { height = 24, width = len }
   end
   
   local coords
   menu_fn = function(auto_popped)
      if not auto_popped then
         coords = mouse.coords()
      end
      if menu then
         if menu.wibox.visible then
            menu:hide()
            menu = nil
            return
         else
            menu = nil
         end
      end
      
      if not next(status) then
         local entries = {{ "No Bluetooth info", function() end }}
         set_entries_size(entries)
         menu = awful.menu.new(entries)
         menu:show({ coords = coords })
         return
      end
      
      local entries = {}
      table.insert(entries, { "Powered", function()
         run(BLUETOOTHCTL_FAST .. " power " .. (status.powered == "yes" and "off" or "on"))
      end, status.powered == "yes" and beautiful.check_icon or nil })
      table.insert(entries, { "Pairable", function()
         run(BLUETOOTHCTL_FAST .. " pairable " .. (status.pairable == "yes" and "off" or "on"))
      end, status.pairable == "yes" and beautiful.check_icon or nil })
      table.insert(entries, { "Discoverable", function()
         run(BLUETOOTHCTL_FAST .. " discoverable " .. (status.discoverable == "yes" and "off" or "on"))
      end, status.discoverable == "yes" and beautiful.check_icon or nil })

      local devices = {}
      local scan = pread(BLUETOOTHCTL_FAST .. " devices")
      for mac, _ in scan:gmatch("Device ([^%s]*) ([^\n]*)") do
         devices[mac] = get_bt_info(mac)
         devices[mac].mac = mac
         devices[mac].name = devices[mac].name or mac
      end

      local devices_array = {}
      for _, v in pairs(devices) do
         table.insert(devices_array, v)
      end
      table.sort(devices_array, function(a,b) 
         if a.name ~= a.mac and b.name == b.mac then
            return true
         end
         if b.name ~= b.mac and a.name == a.mac then
            return false
         end
         return a.name:lower() > b.name:lower()
      end)
      
      local function state(d, connected, paired, other)
         return d.connected == "yes" and connected or (d.paired == "yes" and paired or other)
      end
      
      for _, d in ipairs(devices_array) do
         table.insert(entries, {
            (d.name .. state(d, " (connected)", " (paired)", "")):gsub(" +", " "),
            function()
               if d.paired == "no" or d.trusted == "no" then
                  pair(d.mac)
               else
                  if d.connected == "no" then
                     connect(d.mac)
                  else
                     disconnect(d.mac)
                  end
               end
            end,
            get_icon(state(d, 100, 60, 30)),
         })
      end

      if is_scanning() then
         table.insert(entries, { " Scanning..." })
      elseif #entries == 0 and not auto_popped then
         table.insert(entries, { " Scanning..." })
         is_scanning = rescan()
      else
         table.insert(entries, { " Rescan", function() is_scanning = rescan() end } )
      end

      set_entries_size(entries)
      compact_entries(entries)
      menu = awful.menu.new(entries)
      menu:show({ coords = coords })
   end
   
   widget:buttons(awful.util.table.join(
      awful.button({ }, 1, function() menu_fn() end ),
      awful.button({ }, 3, function() menu_fn() end )
   ))
   
   local bt_timer = timer({timeout=2})
   bt_timer:connect_signal("timeout", update)
   update()
   bt_timer:start()
   
   return widget
end

return bluetooth

