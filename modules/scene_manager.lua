local M = {}

-- Local helpers & state
local callback_registry = {}
local next_callback_id   = 0

M.current_scene   = nil             -- userdata url of the current proxy
M.current_proxy   = nil             -- userdata url of the current proxy
M.loading         = false
M.loaded          = {}              -- [scene_key:string] = proxy_url:userdata
M.pending_unloads = {}              -- [scene_key:string] = callback:function
M.transition      = {               -- transaction settings
  duration = 0.5,
  easing   = gui.EASING_INOUTSINE,
  url      = nil                    -- set by set_transition_handler()
}

-- Turn either a string ("main:/foo#bar") or a msg.url into that exact literal key
--- @param u string The URL to convert to a string
--- @return string The string representation of the URL
local function url_to_string(u)
  if type(u) == "string" then
    return u
  end
  -- tostring(u) is typically "url: [main:/foo#bar]"
  local s = tostring(u)
  return s:match("%[(.-)%]") or s
end

-- Unique IDs for GUI callbacks
--- Generates a unique callback ID for GUI transactions
--- @return string A unique callback ID
local function generate_callback_id()
  next_callback_id = next_callback_id + 1
  return "cb_" .. next_callback_id
end

-- Called by transaction.gui_script when transaction completes
--- @param cb_id string The callback ID to look up in the registry
--- @return nil
function M._on_gui_callback(cb_id)
  local cb = callback_registry[cb_id]
  if cb then
    callback_registry[cb_id] = nil
    cb()
  end
end

--  transaction out
--  This is called when the scene is about to be unloaded
--  and the GUI script should start the transition animation.
--- @param cb function Callback to call when the transition is complete
--- @return nil
local function transition_out(cb)
  if not M.transition.url then
    return cb()
  end
  local id = generate_callback_id()
  callback_registry[id] = cb
  msg.post(M.transition.url, "transition_out", { callback_id = id })
end

--  transaction in
--  This is called when the scene is loaded and the GUI script
--  should start the transition animation.
--- @param cb function Callback to call when the transition is complete
local function transition_in(cb)
  if not M.transition.url then
    return cb()
  end
  local id = generate_callback_id()
  callback_registry[id] = cb
  msg.post(M.transition.url, "transition_in", { callback_id = id })
end

--- Must be called once at startup, *after* set_transition_handler()
--- to initialize the scene manager.
--- @return nil
function M.init()
  if not M.transition.url then
    error("Call set_transition_handler() before init()")
  end
  M.current_scene   = nil
  M.current_proxy   = nil
  M.loading         = false
  M.loaded          = {}
  M.pending_unloads = {}
end

--  Handle proxy_loaded → enable + transaction in
--  This is called when the scene is loaded and the GUI script
--  should start the transition animation.
--- @param sender The URL of the sender that loaded the proxy
local function on_proxy_loaded(sender)
  local key = url_to_string(sender)
  local proxy = M.loaded[key]

  if proxy then
    msg.post(proxy, "enable")
    M.current_scene = proxy
    M.current_proxy = proxy
    transition_in(function()
      M.loading = false
    end)
  end
end

-- Handle proxy_unloaded → call unload callback
-- This is called when the scene is unloaded and the GUI script
-- should start the transition animation.
--- @param sender The URL of the sender that unloaded the proxy
local function on_proxy_unloaded(sender)
  print("SceneManager.on_proxy_unloaded:", sender)
  local key = url_to_string(sender)
  local cb  = M.pending_unloads[key]
  if not cb then
    print("Warning: Unloaded scene without pending unload callback:", key)
    return
  end
  M.pending_unloads[key] = nil
  if cb then cb() end
end

--- Load a scene (string or url)
--  This will transition out of the current scene, unload it,
--  and load the new scene, transitioning in once loaded.
--- @param scene string The scene to load, as a string or msg.url
--- @return nil
function M.load(scene)
  if not scene then 
    print("Warning: Load called with nil scene")
    return 
  end

  local scene_url = (type(scene)=="string" and msg.url(scene)) or scene
  local key       = url_to_string(scene_url)

  if not scene_url then 
    print("Warning: Load called with invalid scene URL:", scene)
    return 
  end

  if M.loading then 
    print("Warning: Load called while already loading a scene:", key)
    return 
  end

  if M.current_scene and url_to_string(M.current_scene)==key then 
    print("Warning: Load called for already loaded scene:", key)
    return 
  end

  M.loading = true

  transition_out(function()
    if M.current_proxy then
      msg.post(M.current_proxy, "disable")
      msg.post(M.current_proxy, "unload")
      M.loaded[url_to_string(M.current_proxy)] = nil
    end
    M.current_scene = scene_url
    M.current_proxy = scene_url
    M.loaded[key]    = scene_url
    msg.post(scene_url, "load")
  end)
end

--- Unload a scene with optional callback
--- @param scene string The scene to unload, as a string or msg.url
--- @param callback function Optional callback to call after unloading
function M.unload(scene, callback)
  if not scene then 
    print("Warning: Unload called with nil scene")
    return 
  end

  local scene_url = (type(scene)=="string" and msg.url(scene)) or scene
  local key       = url_to_string(scene_url)
  local proxy     = M.loaded[key]
  
  if not proxy then
    print("Warning: Unload called for scene not loaded:", key)
    return 
  end

  transition_out(function()
    msg.post(proxy, "disable")
    msg.post(proxy, "unload")

    M.loading = false
    
    if callback then      
      -- M.pending_unloads[key] = callback
      callback()
    end
    
    M.loaded[key] = nil
  end)

  if M.current_scene == proxy then
    M.current_scene = nil
    M.current_proxy = nil
  end
end

--- Get the currently loaded scene
--- @return url The URL of the currently loaded scene, or nil if none is loaded
function M.get_current_scene()
  return M.current_scene
end

--- Set the GUI script URL that handles transaction_in/transaction_out
--- This should be called once at startup to set the GUI script that will handle transitions.
--- @param gui_script_url string The URL of the GUI script that handles transitions
function M.set_transition_handler(gui_script_url)
  M.transition.url = gui_script_url
end

--- Forwarded from your main script’s on_message()
--- This function handles messages related to scene loading and unloading.
--- @param self table The scene manager instance
--- @param message_id hash The ID of the message received
--- @param message table The message data
--- @param sender url The sender of the message
--- @return nil
function M.on_message(self, message_id, message, sender)
  print("SceneManager.on_message:", message_id, message, sender)
  if message_id     == hash("proxy_loaded")        then on_proxy_loaded(sender)
  elseif message_id == hash("proxy_unloaded")      then on_proxy_unloaded(sender)
  elseif message_id == hash("transition_complete") then M._on_gui_callback(message.callback_id)
  end
end

return M
