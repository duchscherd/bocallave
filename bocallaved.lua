#!/usr/bin/env lua5.3

local posix = require("posix")
local json = require("cjson.safe")
local hmac = require("openssl.hmac")

-- Local global variables

local g = {}
g.prog_name = posix.basename(arg[0]) -- Program name
g.debug = false			     -- Output debuging messages
g.background = true		     -- Run in background
g.syslog = true                      -- Log to syslog
g.config_file = "/etc/bocallaved.conf" -- Default location for configuration file
g.user = "bocallave"		     -- User to run as

-- Process command line options

do
   local usage = function ()
      io.write(string.format("\nUsage: %s [options]\n\n",g.prog_name))
      for i,v in ipairs({
	    { "-f", "run in the foreground" },
	    { "-c <file>", "path to configuration file" }, 
	    { "-d", "output debugging messages" },
	    { "-h", "display this help" },
	    { "-s", "send output to stdout" },
	    { "-u <username>", "set name of users to run as" } }) do
	 io.write(string.format("   %-12s %s\n", table.unpack(v)))
      end
      io.write("\n")
      os.exit()
   end

   local unrecongized = function ()
      io.write(string.format("%s: unrecognized option specified\n", g.prog_name))
      usage()
   end
   
   local last_index = 1
   for r, optarg, optind in posix.getopt(arg, 'fdhsc:u:') do
      if r == '?' then
	 unrecongized()
      end
      last_index = optind
      if r == 'h' then
	 usage()
      end
      if r == 'd' then
	 g.debug = true
      end
      if r == 'u' then
	 g.user = optarg
      end
      if r == 'f' then
	 g.background = false
      end
      if r == 's' then
	 g.syslog = false
      end
      if r == 'c' then
	 g.config_file = optarg
      end
   end
   
   if #arg - last_index >= 0 then
      unrecongized(arg[last_index])
   end

end

-- Logging

do
   local logger = {}
   
   if g.syslog then 		-- Log to syslog

      -- Close all filehandles

      local maxfd = 32
      local sysconf = posix.sysconf()
      if sysconf["OPEN_MAX"] then maxfd = sysconf["OPEN_MAX"] end
      for i=0,maxfd do posix.close(i) end
   
      -- Map logger levels to syslog levels
      
      local map = {
	 debug   = posix.LOG_DEBUG,
	 info    = posix.LOG_INFO,
	 warning = posix.LOG_NOTICE,
	 error   = posix.LOG_WARNING,
	 fatal   = posix.LOG_CRIT
      }
      
      posix.openlog(g.prog_name, 'np', posix.LOG_DAEMON)
      for k,v in pairs(map) do
	 if not g.debug and k == "debug" then -- filter debug messages
	    logger[k] = function(msg, ...) end
	 else
	    logger[k] = function (msg, ...)
	       posix.syslog(v, string.upper(k) .. ": " .. string.format(msg, ...))
	    end
	 end
      end

   else
      
      -- Log to stdout
     
      for k,v in ipairs({ "debug", "info", "warning", "error", "fatal" }) do
	 if not g.debug and v == "debug" then -- filter debug messages
	    logger[v] = function(msg, ...) end
	 else
	    logger[v] = function (msg, ...)
	       io.write(string.upper(v) .. ": " .. string.format(msg, ...), "\n")
	    end
	 end
      end
      
   end

   g.log = logger
end

-- Handle signals.  Exit when  SIGINT and SIGTERM are received.

do
   local exit = function ()
      g.log.info("recieved signal .. exiting")
      os.exit()
   end
   posix.signal(posix.SIGINT, exit)
   posix.signal(posix.SIGTERM, exit)
end

-- Helper functions

function string.tohex(str)	-- convert binary string to hex
    return (str:gsub('.', function (c)
        return string.format('%02x', string.byte(c))
    end))
end

function panic (msg, v, ...)	-- log and exit on error
   if v == nil then
      local info = debug.getinfo(2)
      if msg then
	 if select("#", ...) > 0 then
	    g.log.fatal("%s:%s: %s [%s]", info.name or info.what, info.currentline, msg, ...)
	 else
	    g.log.fatal("%s:%s: %s", info.name or info.what, info.currentline, msg)
	 end
      else
	 g.log.fatal("%s:%s: %s", info.name or info.what, info.currentline, ...)
      end
      os.exit(-1)
   end
   
   return v, ...
end

function create_token (key, ip, time)	-- create token
   hash = panic("creating hash", hmac.new(key, "sha256"))
   return hash:final(ip, time):tohex()
end

-- Go into the background

if g.background then

   -- Fork and drop controlling terminal

   local pid = panic("first fork failed", posix.fork())
   if pid ~= 0 then
      os.exit()
   end
   
   panic("setpid failed", posix.setpid('s'))

   local pid = panic("second fork failed", posix.fork())
   if pid ~= 0 then
      os.exit()
   end

   -- Clean up environment

   posix.umask("0")

   panic(nil, posix.chdir("/"))
   
   for a,b in pairs(posix.getenv()) do
      posix.setenv(a)
   end
   
end

-- Drop privs

do
   local pw = panic("invalid user: " .. g.user, posix.getpwnam(g.user))
   local grp = panic("invalid group id: " .. pw.pw_gid, posix.getgrgid(pw.pw_gid))
   
   panic("unable to change to group: " .. grp.gr_name, posix.setpid("g", pw.pw_gid))
   panic("unable to change to user: " .. g.user, posix.setpid("u", pw.pw_uid))
end

-- Read configuration file

do
   local fh = panic("reading configurationo file", io.open(g.config_file))
   g.config = panic("invalid configuration file", json.decode(fh:read("*all")))
end

-- Main

do
   local slist = {}
   for i,config in ipairs(g.config) do
      local s = panic("creating socket for " .. config.name,
		      posix.socket(posix.AF_INET, posix.SOCK_DGRAM, 0))
      panic("binding socket for " .. config.name,
	    posix.bind(s, { family=posix.AF_INET,	
			    protocol=posix.IPPROTO_UDP,
			    port=config.port,
			    addr=config.address }))

      slist[s] = { events = { IN=true }, config = config }

      g.log.info("%s: listening on %s:%s", config.name, config.address, config.port)
   end

   while true do
      panic("poll failed", posix.poll(slist, -1))
      for s in pairs(slist) do
	 if slist[s].revents.IN then
	    config = slist[s].config
	    
	    local token, sender = panic("reading frmo socket", posix.recvfrom(s, 1024))
	    g.log.info("%s: received packet from %s:%s", config.name, sender.addr, config.port);

	    local time = math.floor(posix.time() / 5)
	    for i,v in ipairs({ 0, -1, 1 }) do
	       ctoken = create_token(config.secret, sender.addr, time - v)
	       if token == ctoken then

		  -- Prepare environment
		  posix.setenv("src_ip", sender.addr, true)
		  posix.setenv("src_port", sender.port, true)
		  posix.setenv("dst_ip", config.address, true)
		  posix.setenv("dst_port", config.port, true)
		  posix.setenv("config_name", config.name, true)

		  -- Run command and capture its output
		  g.log.info("%s: running command: %s", config.name, config.command)
		  local p, err = io.popen(config.command .. " 2>&1", 'r')
		  if p == nil then
		     g.log.error("%s: pipe failed: %s", config.name, err)
		     break
		  end
		  local output = p:read("*a")
		  rv = { p:close() }

		  if rv[1] == nil then
		     if rv[2] == "exit" then
			g.log.error("%s: command failed with error code %s", config.name, rv[3])
		     elseif v[2] == "signal" then
			g.log.error("%s: command exited due to signal %s", config.name,  rv[3])
		     else
			g.log.error("%s: command failed for an unknown reason", config.name)
		     end
		     for line in output:gmatch("[^\n]+") do
			g.log.error("%s: command output: %s", config.name, line)
		     end
		  else
		     g.log.info("%s: command completed successfully", config.name)
		  end
		     
		  break
	       end
	    end
	 end
      end
   end
end
