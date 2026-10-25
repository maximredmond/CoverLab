-- Explicit peer and hostname validation also on KOReader releases whose
-- ssl.https defaults do not verify certificates.
return function(app)
    local M = {}
    function M.matches(cert,host)
        if host:match("^[%d%.]+$") then
            return cert.checkip and cert:checkip(host) == true or false
        end
        if cert.checkhost then return cert:checkhost(host) == true end
        local function same(name)
            if type(name) ~= "string" or name:find("%z") then return false end
            name=name:lower()
            if name:sub(1,2) == "*." then return host:match("^[^.]+%.(.+)$") == name:sub(3) end
            return name == host
        end
        local san=(cert:extensions() or {})["2.5.29.17"]
        if san then
            for _,name in ipairs(san.dNSName or {}) do if same(name) then return true end end
            return false -- SAN takes precedence over Common Name.
        end
        for _,item in ipairs(cert:subject() or {}) do
            if item.name == "commonName" and same(item.value) then return true end
        end
        return false
    end
    function M.create(host,ip)
        local socket,ssl=require("socket"),require("ssl")
        local conn={sock=assert(socket.tcp())}
        function conn:settimeout() return self.sock:settimeout(app.settings:get("connect_timeout")) end
        function conn:connect(request_host,port)
            if request_host ~= host or tonumber(port) ~= 443 then return nil,"Unexpected connection target." end
            self:settimeout()
            local ok,err=self.sock:connect(ip,443)
            if not ok then return nil,err end
            local secured; secured,err=ssl.wrap(self.sock,{mode="client",protocol="any",verify="peer",
                cafile=app.ca_bundle,options={"all","no_sslv2","no_sslv3","no_tlsv1","no_tlsv1_1"}})
            if not secured then self.sock:close(); return nil,err end
            self.sock=secured
            self.sock:sni(host);self:settimeout()
            ok,err=self.sock:dohandshake()
            if not ok then self.sock:close();return nil,err end
            local cert=self.sock:getpeercertificate()
            if not cert or not M.matches(cert,host) then self.sock:close();return nil,"TLS certificate does not match image host." end
            return 1
        end
        return setmetatable(conn,{__index=function(_,key)
            return function(self,...) return self.sock[key](self.sock,...) end
        end})
    end
    return M
end
