-- -*- mode: lua; indent-tabs-mode: nil -*-

function identity(x) return x end

function string.left_common(s1, s2)
   local i = 1
   while s1:sub(i, i) == s2:sub(i, i) do
      i = i + 1
   end
   return s1:sub(1, i - 1)
end

function table.keys(tbl)
   if not tbl then return {} end
   local ret = {}
   for k,_ in pairs(tbl) do
      table.insert(ret, k)
   end
   return ret
end

function string.split(s, sep)
   local ret = {}
   while s:find(sep) do
      local i,j = s:find(sep)
      table.insert(ret, s:sub(1, i-1))
      s = s:sub(j+1)
   end
   if s then
      table.insert(ret, s)
   end
   return ret
end

function double_quote(s)
   return '"' .. (s or "") .. '"'
end

function filter(pred, tbl)
   local function filter_aux(pred, tbl, ret)
      if #tbl == 0 then
         return ret
      else
         if pred(tbl[1]) then
            table.insert(ret, tbl[1])
         end
         return filter_aux(pred, {unpack(tbl, 2)}, ret)
      end
   end

   return filter_aux(pred, tbl, {})
end

function map(f, tbl)
   local function map_aux(f, tbl, ret)
      if #tbl == 0 then
         return ret
      else
         table.insert(ret, f(tbl[1]))
         return map_aux(f, {unpack(tbl, 2)}, ret)
      end
   end

   return map_aux(f, tbl, {})
end

function reduce(f, tbl)
   local function reduce_aux(f, tbl, acc)
      if #tbl == 0 then
         return acc
      else
         return reduce_aux(f, {unpack(tbl, 2)}, f(acc, tbl[1]))
      end
   end

   if not tbl or #tbl == 0 then
      return nil
   else
      return reduce_aux(f, {unpack(tbl, 2)}, tbl[1])
   end
end

function print_capture()
   local self = { out={} }
   local mt   = { __call = function(...) table.insert(self.out, table.concat(arg, "\t", 2)) end }
   setmetatable(self, mt)
   return self
end

function encode_message(command)
   return string.format("%06x", command:len()) .. command
end

function sexpr2table(s)
   local function sexpr2table_aux(s)
      local inside_quote = false
      local escaping     = false
      local chunk        = nil
      local ret          = {}
      local i            = 1
      while i <= s:len() do
         local c = s:sub(i, i)
         if escaping then
            chunk = (chunk or "") .. c
            escaping = false
         elseif c == '\\' then
            escaping = true
         elseif inside_quote then
            if c == '"' then
               inside_quote = not inside_quote
            else
               chunk = (chunk or "") .. c
            end
         elseif c == ' ' or c == ')' then
            if chunk then
               table.insert(ret, chunk)
               chunk = nil
            end
            if c == ')' then break end
         elseif c == '(' then
            local n, t = sexpr2table_aux(s:sub(i + 1))
            table.insert(ret, t)
            i = i + n 
         elseif c == '"' then
            inside_quote = not inside_quote
         else
            chunk = (chunk or "") .. c
         end
         i = i + 1
      end
      return i, ret
   end
   local i, t = sexpr2table_aux(s)
   return t[1]
end

-- t = sexpr2table('(:emacs-rex (swank:connection-info) "COMMON-LISP-USER" t 1)\n')
-- t = sexpr2table('(:emacs-rex (swank:listener-eval "\"abc\"\n") "LUA" :repl-thread 4)')
-- t = sexpr2table('(:emacs-rex (swank:listener-eval "print(1)\n") "LUA" :repl-thread 7)')

-- t = sexpr2table('(:emacs-rex (swank:listener-eval "\"abc\"\n") "LUA" :repl-thread 5)')
-- t = sexpr2table('(swank:listener-eval "\"abc\"\n")')
-- t = sexpr2table('(:emacs-rex (swank:listener-eval "\'abc\'\n") "LUA" :repl-thread 5)')
-- for k,v in ipairs(t) do
--    print(k,v)
-- end

function table2sexpstr(tbl)
   local ret = nil
   for k,v in pairs(tbl) do
      if type(v) == "table" then
         v = table2sexpstr(v)
      end
      if ret then
         ret = ret .. " " .. v
      else
         ret = v
      end
   end
   if ret then
      return "(" .. ret .. ")"
   else
      return "nil"
   end
end

function return_message(data, serial)
   return table2sexpstr({":return", data, serial})
end

function return_ok_message(data, serial)
   return return_message({":ok", data}, serial)
end

function return_abort_message(data, serial)
   return return_message({":abort", data}, serial)
end

function write_string_message(s, is_result)
   if is_result then
      return table2sexpstr({":write-string", s, ":repl-result"})
   else
      return table2sexpstr({":write-string", s})
   end
end

local swank = {}

function swank.eval(self, str, serial, is_listener)
   local eval_str = "return " .. str
   self.logger("str", eval_str)
   local eval = loadstring(eval_str)
   if not eval then
      eval = loadstring(str)
   end
   if not eval then
      return nil, {}
   end
   local print_orig = _G.print
   local p = print_capture()
   _G.print = p
   local status, ret = pcall(eval)
   _G.print = print_orig
   self.logger("ret", ret)
   return self:result_message(serial, status, ret, p.out, is_listener)
end

function swank.completions(self, args, serial)
   local names = args[1]:split('%.')
   local prefix, base = {unpack(names, 1, #names-1)}, names[#names]
   local g = _G
   for _, name in ipairs(prefix) do
      g = g[name]
      if not g then break end
   end
   local function prepend_prefix(x)
      local s = table.concat(prefix, ".")
      if s:len() > 0 then
         return s .. "." .. x
      end
      return x
   end
   local candidates = filter(function(x) return x:find("^" .. base .. ".*" ) end, table.keys(g))
   return return_ok_message({map(double_quote, map(prepend_prefix, candidates)),
                             double_quote(reduce(string.left_common, 
                                                 map(prepend_prefix, candidates)))}, serial), {}
end

function swank.listener_eval(self, args, serial)
   if args[1] == '\n' then
      selfl.ua_command = nil   -- reset
   end
   self.lua_command = (self.lua_command or "") .. '\n' .. args[1]
   self.lua_command = self.lua_command:gsub("^%s*", ""):gsub("%s*$", "")
   self.logger(self.lua_command:len(), self.lua_command)
   if self.lua_command:len() == 0 then
      return return_ok_message('nil', serial), {}
   else
      local control_msg, write_str = self:eval(self.lua_command, serial, true)
      if control_msg then
         self.lua_command = nil
      else
         control_msg = return_ok_message('nil', serial)
      end
      return control_msg, write_str
   end
end

function swank.connection_info(self, args, serial)
   local function getpid()
      return tonumber(io.open("/proc/self/stat"):read():split(' ')[1])
   end

   local connection_response = 
   {":encoding",
    {":coding-system", [["utf-8"]], ":external-format", [["UTF-8"]]},
    ":lisp-implementation",
    {":name", [["LUA"]], ":type", [["LUA"]], ":version", [["0.1"]]},
    ":package",
    {":name", [["LUA"]], ":prompt", [["LUA"]]},
    ":pid", getpid(),
    ":version", [["2011-06-21"]]}

   return return_ok_message(connection_response, serial), {}
end

function swank.swank_require(self, args, serial)
   return return_ok_message({}, serial), {}
end

function swank.create_repl(self, args, serial)
   return return_ok_message({[["LUA"]], [["LUA"]]}, serial), {}
end

function swank.quit_lisp(self, args, serial)
   os.exit(0)
   return return_ok_message('nil', serial), {}
end

function swank.buffer_first_change(self, args, serial)
   return return_ok_message(":not-available", serial), {}
end

function swank.autodoc(self, args, serial)
   return return_ok_message(":not-available", serial), {}
end

function swank.interactive_eval_region(self, args, serial)
   return swank.eval(self, args[1], serial, false)
end

function swank.result_message(self, serial, status, ret, print_messages, is_listener)
   local write_str = {}
   if status then
      for _, msg in pairs(print_messages) do
         table.insert(write_str, write_string_message(double_quote(msg), false))
         table.insert(write_str, write_string_message('"\n"', false))
      end
      if is_listener then
         table.insert(write_str, write_string_message(double_quote(tostring(ret)), true))
         table.insert(write_str, write_string_message('"\n"', true))
         return return_ok_message('nil', serial), write_str
      else
         return return_ok_message(tostring(ret), serial), write_str
      end
   else
      return return_abort_message(double_quote(ret:gsub('"', '\\"')), serial), write_str
   end
end

function swank.load_file(self, args, serial)
   local print_orig = _G.print
   local p = print_capture()
   _G.print = p
   local status, ret = pcall(dofile, args[1])
   _G.print = print_orig
   return self:result_message(serial, status, ret, p.out, false)
end

local dispatcher = {
   ['swank:connection-info']         = swank.connection_info,
   ['swank:swank-require']           = swank.swank_require,
   ['swank:create-repl']             = swank.create_repl,
   ['swank:quit-lisp']               = swank.quit_lisp,
   ['swank:buffer-first-change']     = swank.buffer_first_change,
   ['swank:autodoc']                 = swank.autodoc,
   ['swank:completions']             = swank.completions,
   ['swank:interactive-eval-region'] = swank.interactive_eval_region,
   ['swank:listener-eval']           = swank.listener_eval,
   ['swank:load-file']               = swank.load_file,
}

local socket = require("socket");
local host   = host or "localhost";
local port   = port or "4005";
local server = assert(socket.bind(host, port));

swank.logger = print

while 1 do
   swank.logger("server: waiting for client connection...");
   control = assert(server:accept())
   while 1 do 
      local len     = tonumber(assert(control:receive(6)), 16)
      local command = assert(control:receive(len))
      swank.logger("command", command)
      command = sexpr2table(command)
      local serial        = tonumber(command[5])
      local swank_command = command[2][1]
      local swank_args    = {unpack(command[2], 2)}
      local control_msg, write_str = nil, {}
      swank.logger("swank_command", swank_command)
      for k,v in ipairs(command[2]) do
         swank.logger(k,v)
      end
      local func = dispatcher[swank_command]
      if func then
         control_msg, write_str = func(swank, swank_args, serial)
      end
      swank.logger("response", control_msg)
      swank.logger()
      for _, str in pairs(write_str) do
         control:send(encode_message(str))
      end
      if control_msg then
         command = ""
         control:send(encode_message(control_msg))
      end
   end
end
